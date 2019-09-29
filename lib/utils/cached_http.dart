import 'dart:io';
import 'dart:typed_data';

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
  final client = HttpClient();
  final _loading = Map<String, _Item>();

  CachedHttp._(Directory dir) : cache = LruFileCache(dir, defaultMaxSize);

  Future _open() async {
    await cache.open();
  }

  Future<bool> downloadFile(String url, File file, {String method,
      Map<String, String> headers}) async {
    final tmpFile = File(file.path + '.p');
    IOSink out;
    try {
      final response = await openUrl(url, method: method, headers: headers);
      if (response.statusCode < HttpStatus.ok || response.statusCode >= HttpStatus.multipleChoices)
        throw Exception(response.reasonPhrase);

      out = tmpFile.openWrite();
      await response.pipe(out);
      await tmpFile.rename(file.path);
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
      return true;
    } catch (e) {
      await out?.close();
      deleteFile(tmpFile);
      print('HttpCache download $url: $e');
      return false;
    }
  }

  Future<dynamic> getAsJson(String url, {String method,
      Map<String, String> headers, CheckCacheHeaders checkCache}) async {
    final file = await getFile(url, method: method, headers: headers, checkCache: checkCache);
    dynamic result;
    IOSink out;
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 4 && bytes.buffer.asUint32List(0, 1)[0] == _magicJson) {
        // read from binary message
        return await compute(_decodeJsonFromBinary, ByteData.view(bytes.buffer, 4));
      }

      result = await compute(_decodeJsonFromString, ByteData.view(bytes.buffer));
      out = file.openWrite(encoding: null);

      // write magic head
      final head = Uint8List(4);
      head.buffer.asUint32List()[0] = _magicJson;
      out.add(head);

      // convert to binary message
      final data2 = await compute(_encodeJsonToBinary, result);
      out.add(data2.buffer.asUint8List(0, data2.lengthInBytes));

      // close and update the cache
      await out.close();
      out = null;

      cache.update(hashUrl(url), file);
    } catch (e) {
      await deleteFile(file);
      print('HttpCache decode json $url: $e');
      if (result != null)
        return result;
      throw e;
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

  Future<File> getFile(String url, {String method,
      Map<String, String> headers, CheckCacheHeaders checkCache}) async {
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
      return downloadFile(url, file, method: method, headers: headers);
    });
    _loading.remove(url);
    if (downloaded) cache.update(item.key, file);
    return file;
  }

  Future<HttpClientResponse> openUrl(String url, {String method,
      Map<String, String> headers}) async {
    final request = await client.openUrl(method ?? 'GET', Uri.parse(url));
    headers?.forEach((k, v) => request.headers.add(k, v));
    return request.close();
  }

  static dynamic _decodeJsonFromBinary(ByteData data) => StandardMessageCodec().decodeMessage(data);

  static dynamic _decodeJsonFromString(ByteData data) => JSONMessageCodec().decodeMessage(data);

  static ByteData _encodeJsonToBinary(dynamic json) => StandardMessageCodec().encodeMessage(json);

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
