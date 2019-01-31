import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class BufferReader extends ReadBuffer {

  BufferReader(ByteData data) : super(data);

  factory BufferReader.from(Uint8List data) => BufferReader(ByteData.view(data.buffer));

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

class BufferWriter extends WriteBuffer {

  void putSize(int value) {
    assert(0 <= value && value <= 0xffffffff);
    if (value < 254) {
      putUint8(value);
    } else if (value <= 0xffff) {
      putUint8(254);
      putUint16(value);
    } else {
      putUint8(255);
      putUint32(value);
    }
  }

  void putString(String value) {
    final data = utf8.encoder.convert(value);
    putSize(data.length);
    putUint8List(data);
  }

  @override
  @Deprecated("Use convenient doneToBytes() instead")
  ByteData done() => super.done();

  Uint8List doneToBytes() {
    final data = super.done();
    return data.buffer.asUint8List(0, data.lengthInBytes); // return the correct length in bytes
  }
}