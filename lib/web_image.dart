import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'utils/cached_http.dart';

class WebImage extends Image {
  WebImage(String url, {double width, double height, BoxFit fit, double scale = 1.0, bool shrink = true, Map<String, String> headers, Key key}) : super(
    key: key,
    width: width, height: height, fit: fit,
    image: WebImageProvider(url, scale: scale, shrink: shrink, width: width, height: height, headers: headers)
  );
}

final _singleFrameProviders = Set<ImageProvider>();

class WebImageProvider extends ImageProvider<WebImageProvider> {
  final String url;
  final double width;
  final double height;
  final double scale;
  final bool shrink;
  final Map<String, String> headers;

  WebImageProvider(this.url, {this.width, this.height, this.scale = 1.0, this.shrink = true, this.headers});

  @override
  Future<WebImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<WebImageProvider>(this);
  }

  @override
  ImageStreamCompleter load(WebImageProvider key) {
    final codec = _loadAsync(key);
    return (shrink ?? true)
      ? ShrinkImageStreamCompleter(codec, key, width: width, height: height, scale: scale)
      : MultiFrameImageStreamCompleter(codec: codec, scale: scale);
  }

  @override
  bool operator ==(dynamic obj) {
    if (obj.runtimeType != runtimeType) return false;
    final WebImageProvider other = obj;
    return url == other.url
        && width == other.width
        && height == other.height
        && scale == other.scale
        && shrink == other.shrink;
  }

  @override
  int get hashCode => hashValues(url, width, height, scale, shrink);

  @override
  String toString() => '$runtimeType($url, ${width}x$height@$scale)';

  static Future<ui.Codec> _loadAsync(WebImageProvider key) async {
    final http = await CachedHttp.singleton();
    final file = await http.getFile(key.url, headers: key.headers);
    Uint8List data;
    try {
      data = await file.readAsBytes();
      if (data == null || data.lengthInBytes == 0) throw Exception('Empty cache: ${key.url}, ${file.path}');
    } catch (e) {
      print('Load failed: ${key.url}, ${file.path}');
      return null;
    }

    final density = ui.window.devicePixelRatio;
    final targetWidth = key.width != null ? (key.width * density).round() : null;
    final targetHeight = key.height != null ? (key.height * density).round() : null;

    // need only one to keep aspect ratio
    var result = await _instantiateImageCodec(key, data,
                        targetWidth: targetWidth,
                        targetHeight: targetWidth == null ? targetHeight : null);
    if (result != null) return result;
    else if (targetWidth != null || targetHeight != null)
      result = await _instantiateImageCodec(key, data);
    return result;
  }

  static Future<ui.Codec> _instantiateImageCodec(WebImageProvider key, Uint8List data,
                          {int targetWidth, int targetHeight}) async {
    try {
      final codec = await ui.instantiateImageCodec(data,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      if (codec.frameCount == 1) _singleFrameProviders.add(key);
      return codec;
    } catch (e) {
      print('load image failed: ${key.url}, ${key.width}x${key.height}@${key.scale}, $e');
    }
    return null;
  }
}

class ShrinkImageStreamCompleter extends MultiFrameImageStreamCompleter {
  ImageProvider key;
  double width;
  double height;

  OneFrameImageStreamCompleter _oneFrameCompleter;

  ShrinkImageStreamCompleter(Future<ui.Codec> codec, this.key, {this.width, this.height, double scale})
    : super(codec: codec, scale: scale);

  @override
  void addListener(ImageStreamListener listener) {
    if (_oneFrameCompleter != null) {
      _oneFrameCompleter.addListener(listener);
    } else {
      super.addListener(listener);
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    _oneFrameCompleter?.removeListener(listener);
    super.removeListener(listener);
  }

  @override
  void setImage(ImageInfo image) {
    final shouldShrink = !(image is _ShrinkedImage);
    final size = shouldShrink ? _IntSize.scale(image.image, width, height) : null;
    if (shouldShrink && _shouldShrinkImage(image.image, size.width, size.height)) {
      _shrinkImage(image.image, size).then((shrinkedImage) {
        if (_singleFrameProviders.remove(key)) {
          _oneFrameCompleter = OneFrameImageStreamCompleter(Future.sync(() => shrinkedImage));
          imageCache.evict(key);
          imageCache.putIfAbsent(key, () => _oneFrameCompleter);
        }
        super.setImage(shrinkedImage);
      });
    } else {
      super.setImage(image);
    }
  }

  Future<_ShrinkedImage> _shrinkImage(ui.Image image, _IntSize size) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.low;
    canvas.scale(size.width / image.width.toDouble());
    canvas.drawImage(image, Offset.zero, paint);
    final image2 = await recorder.endRecording().toImage(size.width, size.height);
    print('shrink image: $key, ${image.width}x${image.height} -> ${image2.width}x${image2.height}');
    return _ShrinkedImage(image2);
  }

  static bool _shouldShrinkImage(ui.Image image, int width, int height) {
    if (width > 0 && height > 0)
      return image.width > width * 9 / 8 && image.height > height * 9 / 8;
    else
      return (width > 0 && image.width > width * 9 / 8) || (height > 0 && image.height > height * 9 / 8);
  }
}

class _IntSize {
  final int width;
  final int height;

  _IntSize(this.width, this.height);

  factory _IntSize.scale(ui.Image image, double widgetWidth, double widgetHeight) {
    final density = ui.window.devicePixelRatio;
    final width2 = (widgetWidth ?? 0.0) * density;
    final height2 = (widgetHeight ?? 0.0) * density;
    double scaleX = width2 / image.width;
    double scaleY = height2 / image.height;
    double scale = scaleX > scaleY ? scaleX : scaleY;
    return _IntSize((image.width * scale).round(), (image.height * scale).round());
  }
}

class _ShrinkedImage extends ImageInfo {
  _ShrinkedImage(ui.Image image) : super(image: image, scale: 1.0);
}
