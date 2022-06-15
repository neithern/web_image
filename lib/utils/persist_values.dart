import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

Future<Directory> documentsDirectory() async {
  Directory dir;
  try {
    dir = await getApplicationDocumentsDirectory();
  } on MissingPluginException catch (_) {
    dir = Directory.systemTemp.parent;  // for other VMs
  }
  return dir;
}

class PersistValues {
  static const kSingletonName = '_persist_values';
  static const kDelayToSave = Duration(seconds: 1);

  static final kLock = Lock(reentrant: true);
  static final kTypeSet = Map<Type, int>();
  static PersistValues _instance;

  static Future<PersistValues> of(String name) async {
    assert(_instance == null || _instance._name != name);
    final values = PersistValues._(name);
    await values._load();
    return values;
  }

  static Future<PersistValues> singleton() async {
    if (_instance == null) {
      return kLock.synchronized(() async {
        if (_instance == null) {
          final values = PersistValues._(kSingletonName);
          await values._load();
          _instance = values;
        }
        return _instance;
      });
    }
    return _instance;
  }

  final _cache = Map<String, Object>();
  final Lock _lock;
  final String _name;
  String _path;
  Timer _timer;

  PersistValues._(this._name) : _lock = kSingletonName == _name ? kLock : Lock(reentrant: true);

  int get length => _cache.length;

  Iterable<String> get keys => _cache.keys;

  /// support types defined in [StandardMessageCodec].
  dynamic operator [](String key) => _cache[key];

  void operator []=(String key, dynamic value) {
    if (value == null)
      _cache.remove(key);
    else
      _cache[key] = value;
    _delaySave();
  }

  void clear() {
    _cache.clear();
    _delaySave();
  }

  bool contains(String key) => _cache.containsKey(key);

  /// help functions, same as [SharedPreferences]
  bool getBool(String key) => _cache[key];
  int getInt(String key) => _cache[key];
  double getDouble(String key) => _cache[key];
  String getString(String key) => _cache[key];
  List<int> getIntList(String key) => _getList<int>(key);
  List<double> getFloatList(String key) => _getList<double>(key);
  List<String> getStringList(String key) => _getList<String>(key);
  void remove(String key) => this[key] = null;
  void setBool(String key, bool value) => this[key] = value;
  void setInt(String key, int value) => this[key] = value;
  void setDouble(String key, double value) => this[key] = value;
  void setString(String key, String value) => this[key] = value;
  void setIntList(String key, List<int> value) => this[key] = value;
  void setFloatList(String key, List<double> value) => this[key] = value;
  void setStringList(String key, List<String> value) => this[key] = value;

  List<T> _getList<T>(String key) {
    try {
      List list = _cache[key];
      if (list is! List<T>)
        list = _cache[key] = list.cast<T>().toList();
      return list;
    } catch (_) {
      List<T> list = _cache[key] = List<T>.empty(growable: true);
      return list;
    }
  }

  Future _load() async {
    final dir = await documentsDirectory();
    return _lock.synchronized(() async {
      try {
        _path = dir.path + '/' + _name;
        final Uint8List bytes = await File(_path).readAsBytes();
        final data = bytes.buffer.asByteData();
        final map = StandardMessageCodec().decodeMessage(data);
        if (map is Map)
          map.forEach((key, value) => _cache[key] = value);
      } catch (_) {
      }
    });
  }

  Future _save() async {
    return _lock.synchronized(() async {
      try {
        final file = File(_path);
        if (_cache.isNotEmpty) {
          final data = StandardMessageCodec().encodeMessage(_cache);
          final bytes = data.buffer.asUint8List(0, data.lengthInBytes);
          await file.writeAsBytes(bytes, flush: true);
        } else if (await file.exists()) {
          file.delete();
        }
      } catch (e) {
        print(e);
      }
    });
  }

  void _delaySave() {
    _timer?.cancel();
    _timer = new Timer(kDelayToSave, _save);
  }
}