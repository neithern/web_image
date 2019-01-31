import 'dart:async';
import 'dart:io';

import 'cache_file.dart';
import 'http_server.dart';

class CachedServer extends BaseHttpServer {

  static CachedServer singleton() => _instance;

  static final _instance = CachedServer._();

  final Zone _zone = Zone.current.fork();

  CachedServer._();

  @override
  Zone get zone => _zone;

  @override
  Future<CachedServer> stop() async {
    super.stop().then((_) => CacheIndex.instances.clear());
    return this;
  }

  @override
  void handleRequest(HttpRequest request) async {
    final url = decodeUrl(request.uri);
    final range = request.headers[HttpHeaders.rangeHeader]?.first;
    print('CacheServer handle $url: $range');

    final response = request.response;
    final cacheFile = CacheFile(url);
    int length;
    Map<String, String> headers;
    try {
      length = await cacheFile.open();
      headers = cacheFile.responseHeaders;
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.close();
      print('CacheServer open $url: $e');
      return;
    }

    final rng = _HttpRange(range, length);
    headers?.forEach((name, value) => response.headers.set(name, value));
    if (range != null) {
      if (rng.start < length) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${rng.start}-${rng.end - 1}/$length');
        response.contentLength = rng.end - rng.start;
        response.statusCode = HttpStatus.partialContent;
      } else {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/$length');
        response.contentLength = rng.end - rng.start;
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      }
    } else {
      response.contentLength = length;
      response.statusCode = HttpStatus.ok;
    }
    print('CacheServer response $url: ${response.headers[HttpHeaders.contentRangeHeader]}');

    cacheFile.read(rng.start, rng.end).pipe(response).then((_) {
      cacheFile.close();
    }).catchError((e, stack) {
      print('CacheServer send $url: $e, $stack');
      response.close();
      cacheFile.close();
    });
  }
} 

class _HttpRange {
  int start;
  int end;

  _HttpRange(String range, int length) {
    start = 0;
    end = length;
    if (range != null) try {
      range = range.toLowerCase();
      if (range.startsWith('bytes='))
        range = range.substring(6);
      final a = range.split('-');
      start = a.length > 0 && a[0].length > 0 ? int.parse(a[0]) : 0;
      end = a.length > 1 && a[1].length > 0 ? int.parse(a[1]) + 1 : length;
    } catch (_) {
    }
  }
}