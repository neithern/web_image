import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class BufferReader extends ReadBuffer {

  BufferReader(ByteData data) : super(data);

  factory BufferReader.from(Uint8List data) => BufferReader(data.buffer.asByteData());

  int getSize() {
    final int value = getUint8();
    switch (value) {
      case 254:
        return getUint16();
      case 255:
        return getUint32();
      default:
        return value;
    }
  }

  String getString() => utf8.decoder.convert(getUint8List(getSize()));
}
