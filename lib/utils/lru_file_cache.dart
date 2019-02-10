import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

Future<Directory> cacheDirectory() async {
  Directory dir;
  try {
    dir = await getTemporaryDirectory();
  } on MissingPluginException catch (_) {
    dir = Directory.systemTemp;  // for other VMs
  }
  return dir;
}

Future deleteFile(File file) async {
  try {
    if (await file.exists())
      await file.delete();
  } catch (_) {
  }
}

class LruFileCache {
  static const _indexName = '/index';
  static const _8Bytes = 8;
	static const _offsetOfSize = _8Bytes;
  static const _offsetOfTime = _8Bytes * 2;
	static const _itemBytes = _8Bytes * 3;
  static const _fakeTime = 0x7FFFFFFFFFFFFFFF;

  final _cache = LinkedHashMap<int, int>(); // key: hash of url, value: position in index file
  final _lock = Lock(reentrant: true);
  final _recycledPositions = LinkedHashSet<int>();
  int _size = 0;
  int _maxPosition = 0;
  RandomAccessFile _indexFile;
  int maxSize;
  final Directory directory;

  LruFileCache(this.directory, this.maxSize);

  int get size => _size;

  Future open() async { 
    return _lock.synchronized(() async {
      if (! await directory.exists())
        await directory.create(recursive: true);

      final watch = Stopwatch()..start();
      _indexFile = await File(directory.path + _indexName).open(mode: FileMode.append);
      await _indexFile.setPosition(0);

      final length = await _indexFile.length();
      final array = List<Uint64List>(length ~/ _itemBytes);
      final buffer = Uint8List(_itemBytes * min(array.length, 1024));
      int bytesInBuffer = 0;
      int offsetInBuffer = 0;
      int count = 0;
      int position = 0;
      _size = 0;
      _maxPosition = 0;
      while (position + _itemBytes <= length) {
        if (offsetInBuffer >= bytesInBuffer) {
          bytesInBuffer = await _indexFile.readInto(buffer);
          offsetInBuffer = 0;
          if (bytesInBuffer < _itemBytes) break;
        }
        final u64s = buffer.buffer.asUint64List(offsetInBuffer, 3);
        final size = u64s[1]; // size
        if (size > 0) {
          final item = Uint64List(2);
          final key = item[0] = u64s[0]; // key
          item[1] = u64s[2]; // time
          array[count++] = item;
          _cache[key] = position;
          _size += size;
        } else {
          // size is 0, it was marked as deleted
          _recycledPositions.add(position);
        }
        offsetInBuffer += _itemBytes;
        position += _itemBytes;
      }
      _maxPosition = position;

      // resort the access order by time
      array.sort((a1, a2) => (a1?.elementAt(1) ?? _fakeTime) - (a2?.elementAt(1) ?? _fakeTime));
      for (final item in array) {
        if (item != null) _positionFromCacheNoLock(item[0]);
        else break;
      }
      print('DiskCache load used ${watch.elapsedMilliseconds} ms, total ${_cache.length} items $_size bytes');
    });
  }

  Future close() async {
    return _lock.synchronized(() async {
      await _indexFile.close();
      _maxPosition = 0;
      _size = 0;
      _cache.clear();
      _recycledPositions.clear();
    });
  }

  Future clear() async {
    await close();
    await directory.delete(recursive: true);
    await open();
  }

  Future<File> getFile(int key) async {
    return _lock.synchronized(() async {
      final position = _positionFromCacheNoLock(key);
      if (position != null) {
        final values = Uint64List(1);
        values[0] = DateTime.now().millisecondsSinceEpoch;
        await _indexFile.setPosition(position + _offsetOfTime);
        await _indexFile.writeFrom(values.buffer.asUint8List());
      }
      return _cacheFileForKey(key);
    });
  }

  Future update(int key, File file) async {
    int _newPosition() {
      if (_recycledPositions.isNotEmpty) {
        final position = _recycledPositions.first;
        _recycledPositions.remove(position);
        return position;
      }
      final position = _maxPosition;
      _maxPosition += _itemBytes;
      return position;
    }

    final bool exists = await file.exists();
    int size = exists ? await file.length() : 0;
    if (exists) {
      final fileInfo = getIndexFile(file);
      if (await fileInfo.exists())
        size += await fileInfo.length();
    }
    final values = Uint64List(3);
    values[0] = key;
    values[1] = size;
    values[2] = exists ? (await file.lastModified()).millisecondsSinceEpoch : 0;
    return _lock.synchronized(() async {
      final position = await _updateCacheNoLock(key, size, ifAbsent: () => _newPosition());
      await _indexFile.setPosition(position);
      await _indexFile.writeFrom(values.buffer.asUint8List());
    });
  }

  File _cacheFileForKey(int key) => File(directory.path + '/' + key.toRadixString(16));

  int _positionFromCacheNoLock(int key) {
    // removing the key and adding it again will make it be last in the iteration order
    int position = _cache.remove(key);
    if (position != null) _cache[key] = position;
    return position;
  }

  Future<int> _updateCacheNoLock(int key, int size, {int ifAbsent()}) async {
    // ensure size of cache
    final maximumSize = maxSize - size;
    while (_size > maximumSize && _cache.isNotEmpty) {
      int first = _cache.keys.first;
      int pos = _cache.remove(first);
      if (pos != null) _size -= await _removeAtNoLock(first, pos);
    }

    // update or insert new cache
    int position = _cache.update(key, (pos) {
      final oldSize = _sizeOfNoLock(pos);
      assert (_size >= oldSize && oldSize >= 0);
      if (_size >= oldSize && oldSize >= 0) _size -= oldSize;
      return pos;
    }, ifAbsent: ifAbsent);
    _size += size;
    return position;
  }

  Future<int> _removeAtNoLock(int key, int position) async {
    final values = Uint64List(1);
    final buffer = values.buffer.asUint8List();
    await _indexFile.setPosition(position + _offsetOfSize);
    await _indexFile.readInto(buffer);
    int size = values[0];
    values[0] = 0;
    await _indexFile.setPosition(position + _offsetOfSize);
    await _indexFile.writeFrom(buffer); // write size as 0
    _recycledPositions.add(position);
 
    final file = _cacheFileForKey(key);
    final fileInfo = getIndexFile(file);
    await deleteFile(file);
    await deleteFile(fileInfo);
    print('DiskCache remove: $size bytes of ${key.toRadixString(16)}, total ${_cache.length} items $_size bytes');
    return size;
  }

  int _sizeOfNoLock(int position) {
    final values = Uint64List(1);
    _indexFile.setPositionSync(position + _offsetOfSize);
    _indexFile.readIntoSync(values.buffer.asUint8List());
    // print('DiskCache find: ${values[0]} bytes');
    return values[0];
  }

  static File getIndexFile(File file) {
    return File(file.path + '.i');
  }
}