import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_image/utils/cache_file.dart';
import 'package:web_image/utils/cached_http.dart';

void main() {
  const url = 'https://mv-cdn1.ylyk.com/audio-1546034479866.mp3';
  final streamCount = Random().nextInt(8) + 2; 

  test('test cache', () async {
    final http = await CachedHttp.singleton();
    await http.cache.clear();

    print('start whole download');
    final watch = Stopwatch()..start();
    final file = await http.getFile(url);
    print('end whole download used ${watch.elapsed}');
    expect(await file.length() > 0, true);
    final bytes = await file.readAsBytes();
    await file.delete();

    print('start range download by $streamCount times');
    watch.reset();
    final cacheFile = CacheFile(url);
    final length = await cacheFile.open();
    expect(bytes.length, length);

    final builder = BytesBuilder();
    final part = length ~/ streamCount;
    int pos = 0;
    for (int i = 0; i < streamCount; i++) {
      final stream = cacheFile.read(pos, i == streamCount - 1 ? length : pos + part);
      await for (final data in stream)
        builder.add(data);
      pos += part;
    }
    print('end range download used ${watch.elapsed}');
    expect(cacheFile.full, true);
    expect(await cacheFile.file.length(), length);
    await cacheFile.close();

    final bytes2 = builder.takeBytes();
    expect(ListEquality().equals(bytes, bytes2), true);
  }, timeout: Timeout.none);
}