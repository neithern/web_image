import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'buffer_io.dart';
import 'cached_http.dart';
import 'lru_file_cache.dart';

class CacheFile {
  final String url;
  final Map<String, String> requestHeaders;
  final CacheIndex _cacheIndex;

  File _file;
  int _key;
  int _length = 0;
  bool _modified = false;
  bool _opening = false;
  HttpClientResponse _fullStream;

  String get _hash => hashCode.toRadixString(16);

  File get file => _file;
  bool get full => _cacheIndex.full;
  Map<String, String> get responseHeaders => _cacheIndex.headers;

  CacheFile(this.url, {this.requestHeaders}) : _cacheIndex = CacheIndex.instance(url);

  Future<int> open() async {
    final http = await CachedHttp.singleton();
    _key = hashUrl(url);
    _file = await http.cache.getFile(_key);

    final indexFile = LruFileCache.getIndexFile(_file);
    _length = await _cacheIndex.accrue(url, indexFile, _openUrl);
    _opening = true;
    // print('CacheFile $_hash: $url is full: $full');
    return _length;
  }

  Future<HttpClientResponse> _openUrl() async {
    final CachedHttp http = await CachedHttp.singleton();
    final headers = requestHeaders != null ? Map.of(requestHeaders) : Map<String, String>();
    headers[HttpHeaders.acceptEncodingHeader] = 'identity';
    headers.remove(HttpHeaders.rangeHeader);
    _fullStream = await http.openUrl(url, headers: headers);
    return _fullStream;
  }

  Stream<List<int>> read([int start, int end]) async* {
    start ??= 0;
    end ??= _length;
    print('CacheFile $_hash read at: $start->$end');

    int index = CacheIndex._posToIndex(start);
    final dataFile = await _file.open(mode: FileMode.append);
    try {
      int pos = CacheIndex._indexToPos(index);
      // read from cache or http
      await dataFile.setPosition(pos);
      while (pos < end && _opening) {
        // read from cache
        print('CacheFile $_hash begin read cache: $pos');
        while (pos < end && _opening && index < _cacheIndex.count && _cacheIndex[index]) {
          final buffer = Uint8List(CacheIndex._blockSize);
          final bytes = await dataFile.readInto(buffer);
          if (bytes == 0) {
            // _cacheIndex[index] = false;
            break;
          }

          final startInBuf = start > pos ? start - pos : 0;
          final endInBuf = min(bytes, end - pos);
          if (endInBuf > startInBuf) {
            // print('CacheFile $_hash read cache: $index $pos ${endInBuf - startInBuf}');
            yield buffer.sublist(startInBuf, endInBuf);
          }
          pos += bytes;
          index++;
        }
        print('CacheFile $_hash end read cache: $pos/$end');
        if (pos >= end || !_opening)
          break; // done or closed

        // find until the next cached block
        final stopIndex = min(_cacheIndex.nextCached(index + 1) ?? _cacheIndex.count, CacheIndex._posToIndex(end - 1) + 1);
        final stopPos = min(CacheIndex._indexToPos(stopIndex), _length);
        int startPos = pos = CacheIndex._indexToPos(index);
        print('CacheFile $_hash begin download: $startPos->$stopPos/$_length');

        // dowload from http and cache to file
        final headers = requestHeaders != null ? Map.of(requestHeaders) : Map<String, String>();
        headers[HttpHeaders.acceptEncodingHeader] = 'identity';
        headers[HttpHeaders.rangeHeader] = 'bytes=$startPos-${stopPos - 1}';
        final http = await CachedHttp.singleton();
        final stream = startPos == 0 && _fullStream != null ? _fullStream : await http.openUrl(url, headers: headers);
        _fullStream = null;
        await dataFile.setPosition(startPos);
        await for (final data in stream) {
          final startInBuf = start > pos ? start - pos : 0;
          final endInBuf = min(data.length, end - pos);
          if (endInBuf > startInBuf)
            yield data.sublist(startInBuf, endInBuf);

          await dataFile.writeFrom(data);
          _modified = true;
          pos += data.length;

          // update index if blocks was cached fully
          while (pos >= min(startPos + CacheIndex._blockSize, _length) && index < _cacheIndex.count) {
            // print('CacheFile $_hash cached: $index $startPos');
            _cacheIndex[index++] = true;
            startPos += CacheIndex._blockSize;
          }
          if (pos >= stopPos)
            break; // done
          if (!_opening && stopPos == _length)
            break; // if closed and to stop end of file then break, else download until stop
        }
        _cacheIndex.writeCurrentByte();
        print('CacheFile $_hash end download: $pos/$end');
      }
    } finally {
      dataFile.close();
    }
  }

  Future close() async {
    final opening = _opening;
    _opening = false;
    await _cacheIndex.release();
    if (opening && _modified) {
      final http = await CachedHttp.singleton();
      http.cache.update(_key, _file);
      _modified = false;
    }
    print('CacheFile $_hash close');
  }
}

class CacheIndex {
  static final instances = Map<String, CacheIndex>();

  static const _shift = 14;
  static const _blockSize = 1 << _shift; // 16384;

  int _refCount = 0;
  int _blocksOffset;
  int _byteIndex;
  int _count;
  int _dataLength;
  Uint8List _blocks;
  RandomAccessFile _file;
  Map<String, String> _headers;

  int get count => _count;
  Map<String, String> get headers => _headers;

  CacheIndex._();

  factory CacheIndex.instance(String url) => instances.putIfAbsent(url, () => CacheIndex._());

  bool get full {
    for (int i = 0; i < _blocks.length - 1; i++) {
      if (_blocks[i] != 0xff)
        return false;
    }
    for (int i = (_blocks.length - 1) >> 3; i < _count; i++) {
      if (!this[i])
        return false;
    }
    return true;
  }

  bool operator [](int index) {
    if (index < 0 || index >= _count)
      throw RangeError.range(index, 0, _count);

    return (_blocks[index >> 3] & (1 << (index % 8))) != 0;
  }

  void operator []=(int index, bool value) {
    if (index < 0 || index >= _count)
      throw RangeError.range(index, 0, _count);

    final byteIndex = index >> 3;
    final mask = 1 << (index % 8);
    final oldValue = _blocks[byteIndex];
    if (value) _blocks[byteIndex] |= mask;
    else _blocks[byteIndex] &= ~mask;
    if (oldValue == _blocks[byteIndex])
      return;

    if (_byteIndex != byteIndex)
      writeCurrentByte();
    _byteIndex = byteIndex;
  }

  int nextCached(int index) {
    while (index < _count) {
      if (this[index]) return index;
      index++;
    }
    return null;
  }

  Future<int> accrue(String url, File file, Future<HttpClientResponse> openUrl()) async {
    if (++_refCount == 1) {
      final raf = await file.open(mode: FileMode.append);
      try {
        final headers = Map<String, String>();
        await raf.setPosition(0);
        final bytes = await readHeaders(url, headers, raf);
        if (bytes > 4) {
          // read blocks
          final length = int.parse(headers[HttpHeaders.contentLengthHeader]);
          if (length == null || length <= 0)
            throw ArgumentError('no length: $url');
          _blocksOffset = bytes;
          _count = _posToIndex(length - 1) + 1;
          _blocks = Uint8List(((_count - 1) >> 3) + 1);
          await raf.readInto(_blocks);
          _headers = headers;
          _file = raf;
          _dataLength = length;
          return _dataLength;
        }
      } catch (e) {
        print('_IndexFile open ${file.path}: $e');
      }

      final response = await openUrl();
      final length = response.contentLength;
      final headers = Map<String, String>();
      response.headers.forEach((name, values) => headers[name] = values[0]);
      // write url and response headers
      await raf.setPosition(0);
      final bytes = await writeHeaders(url, headers, raf);
      _blocksOffset = bytes;
      _count = _posToIndex(length - 1) + 1;
      _blocks = Uint8List(((_count - 1) >> 3) + 1);
      _headers = headers;
      _file = raf;
      _dataLength = length;
      return _dataLength;
    }
    return _dataLength;
  }

  Future release() async {
    if (--_refCount == 0) {
      writeCurrentByte();
      await _file?.close();
      _file = null;
    }
  }

  void writeCurrentByte() {
    if (_byteIndex != null && _blocksOffset != null) {
      _file?.setPositionSync(_blocksOffset + _byteIndex);
      _file?.writeByteSync(_blocks[_byteIndex]);
      _byteIndex = null;
    }
  }

  static int _indexToPos(int index) => index << _shift;
  static int _posToIndex(int pos) => pos >> _shift;

  static Future<int> readHeaders(String url, Map<String, String> headers, RandomAccessFile raf) async {
    final headerSize = Uint32List(1);
    if (await raf.readInto(headerSize.buffer.asUint8List()) == 4) {
      // read url and response headers
      final data = Uint8List(headerSize[0] - 4);
      await raf.readInto(data);
      final reader = BufferReader.from(data);
      final url0 = reader.getString();
      if (url != url0)
        throw ArgumentError('hash conflict ${raf.path}: $url <-> $url0');
      final count = reader.getSize();
      for (int i = 0; i < count; i++) {
        final key = reader.getString();
        headers[key] = reader.getString();
      }
    }
    return headerSize[0];
  }

  static Future<int> writeHeaders(String url, Map<String, String> headers, RandomAccessFile raf) async {
    final writer = BufferWriter();
    writer.putUint32(0); // empty size of header, fix it later
    writer.putString(url);
    writer.putSize(headers.length);
    for (final entry in headers.entries) {
      writer.putString(entry.key);
      writer.putString(entry.value);
    }
    final data = writer.doneToBytes();
    data.buffer.asUint32List(0, 4)[0] = data.lengthInBytes; // fix the size of header
    await raf.writeFrom(data);
    return data.lengthInBytes;
  }
}