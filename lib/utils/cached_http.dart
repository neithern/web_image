import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';

import 'cache_file.dart';
import 'lru_file_cache.dart';

typedef bool CheckCacheHeaders(Map<String, String> responseHeaders);

class CachedHttp {
  static const defaultMaxSize = 200 * 1024 * 1024;

  static const _magicJson = 0x6E6F736A; // 'json'
  static const _pathSub = '/http_cache';

  static final _lock = Lock(reentrant: true);
  static CachedHttp _instance;

  static Future<CachedHttp> singleton() async {
    if (_instance == null) {
      return _lock.synchronized(() async {
        if (_instance == null) {
          // keep local instance till it is fully initialized
          final dir = await cacheDirectory();
          final http = CachedHttp._(Directory(dir.path + _pathSub));
          await http._open();
          _instance = http;
        }
        return _instance;
      });
    }
    return _instance;
  }

  final LruFileCache cache;
  final _loading = Map<String, _Item>();

  CachedHttp._(Directory dir) : cache = LruFileCache(dir, defaultMaxSize);

  Future _open() async {
    await cache.open();
  }

  Future<bool> downloadFile(String url, File file,
                          {String method, Map<String, String> headers, bool autoCompress,
                          StreamController<ImageChunkEvent> chunkEvents}) async {
    final Completer<bool> completer = Completer<bool>.sync();
    HttpClientResponse response;
    try {
      response = await openUrl(url,
        method: method,
        headers: headers,
        autoCompress: autoCompress,
      );
      if (response.statusCode < HttpStatus.ok || response.statusCode >= HttpStatus.multipleChoices)
        throw Exception(response.reasonPhrase);
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      return false;
    }

    final tmpFile = File(file.path + '.p');
    IOSink out;
    try {
      out = tmpFile.openWrite();
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
      return false;
    }

    int expectedContentLength = response.contentLength;
    if (expectedContentLength == -1) expectedContentLength = null;

    int bytesReceived = 0;
    StreamSubscription<List<int>> subscription;
    subscription = response.listen((List<int> chunk) {
      out.add(chunk);
      if (chunkEvents != null) {
        bytesReceived += chunk.length;
        try {
          chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: bytesReceived,
            expectedTotalBytes: expectedContentLength),
          );
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
          subscription.cancel();
        }
      }
    });

    Future _writeHeaders() async {
      // write response headers
      RandomAccessFile raf;
      try {
        final indexFile = LruFileCache.getIndexFile(file);
        final resHeaders = Map<String, String>();
        raf = await indexFile.open(mode: FileMode.write);
        response.headers.forEach((name, values) => resHeaders[name] = values[0]);
        await CacheIndex.writeHeaders(url, resHeaders, raf);
      } finally {
        raf?.close();
      }
    }

    try {
      await subscription.asFuture();
      await out?.close();
      await _writeHeaders();
      await tmpFile.rename(file.path);
      completer.complete(true);
    } catch (error, stackTrace) {
      deleteFile(tmpFile);
      completer.completeError(error, stackTrace);
      completer.complete(false);
    }
    return completer.future;
  }

  Future<dynamic> getAsJson(String url,
                            {String method, Map<String, String> headers, bool autoCompress = true,
                            CheckCacheHeaders checkCache}) async {
    final file = await getFile(url,
      method: method,
      headers: headers,
      autoCompress: autoCompress,
      checkCache: checkCache,
    );
    dynamic result;
    IOSink out;
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 4 && bytes.buffer.asUint32List(0, 1)[0] == _magicJson) {
        // read from binary message
        final data = bytes.buffer.asByteData(4);
        return await StandardMessageCodec().decodeMessage(data);
      }

      final entry = await compute(_jsonStringToBinary, bytes.buffer.asByteData());
      result = entry.key;

      out = file.openWrite(encoding: null);

      // write magic head
      final head = Uint8List(4);
      head.buffer.asUint32List()[0] = _magicJson;
      out.add(head);

      // write binary message
      final data2 = entry.value;
      out.add(data2.buffer.asUint8List(0, data2.lengthInBytes));

      // close and update the cache
      await out.close();
      out = null;

      cache.update(hashUrl(url), file);
    } catch (e) {
      print('HttpCache decode json $url: $e');
      await deleteFile(file);
      if (result == null) throw e;
    } finally {
      await out?.close();
    }
    return result;
  }

  Future<Map<String, String>> getCachedResponseHeaders(String url) async {
    final item = _Item(url);
    final file = await cache.getFile(item.key);
    final responseHeaders = Map<String, String>();
    try {
      await _getResponseHeaders(url, file, responseHeaders);
      return responseHeaders;
    } catch (e) {
      print('HttpCache check $url: $e');
    }
    return null;
  }

  Future<File> getFile(String url,
                      {String method, Map<String, String> headers, bool autoCompress = false,
                      StreamController<ImageChunkEvent> chunkEvents,
                      CheckCacheHeaders checkCache}) async {
    final item = await _lock.synchronized(() => _loading.putIfAbsent(url, () => _Item(url)));
    final file = await cache.getFile(item.key);
    final downloaded = await item.lock.synchronized(() async {
      if (await file.exists() && await file.length() > 0) try {
        final responseHeaders = Map<String, String>();
        await _getResponseHeaders(url, file, responseHeaders);
        if (checkCache == null || checkCache(responseHeaders))
          return false;
      } catch (e) {
        print('HttpCache check $url: $e');
      }
      return downloadFile(url, file,
        method: method,
        headers: headers,
        autoCompress: autoCompress,
        chunkEvents: chunkEvents,
      );
    });
    _loading.remove(url);
    if (downloaded) cache.update(item.key, file);
    return file;
  }

  Future<HttpClientResponse> openUrl(String url,
                                    {String method, Map<String, String> headers,
                                    bool autoCompress = false}) async {
    final httpClient = HttpClient()..autoUncompress = autoCompress;
    final request = await httpClient.openUrl(method ?? 'GET', Uri.parse(url));
    headers?.forEach((k, v) => request.headers.add(k, v));
    return request.close();
  }

  static MapEntry<dynamic, ByteData> _jsonStringToBinary(ByteData data) {
    final json = JSONMessageCodec().decodeMessage(data);
    final data2 = StandardMessageCodec().encodeMessage(json);
    return MapEntry<dynamic, ByteData>(json, data2);
  }

  static Future _getResponseHeaders(String url, File cacheFile, Map<String, String> responseHeaders) async {
    // read and check response headers
    RandomAccessFile raf;
    try {
      final indexFile = LruFileCache.getIndexFile(cacheFile);
      raf = await indexFile.open(mode: FileMode.read);
      await CacheIndex.readHeaders(url, responseHeaders, raf);
    } finally {
      await raf?.close();
    }
  }
}

class _Item {
  final Lock lock = Lock(reentrant: true);
  final int key;

  _Item(String url) : key = hashUrl(url);
}

int hashUrl(String url) {
  final len = url?.length ?? 0;
  int h = 0;
  for (int i = 0; i < len; i++)
    h = h * 31 + (url.codeUnitAt(i) - 32); // characters in url are in ascii table
  return h;
}