import 'package:flutter_test/flutter_test.dart';
import 'package:web_image/utils/persist_values.dart';
// import 'package:shared_preferences/shared_preferences.dart';

Future testConfigs() async {
  await testPersistValues();
  await testSharedPreferencesSet();
}

const kCount = 1000;
const kCount2 = kCount + 1000;

Future testPersistValues() async {
  var begin = DateTime.now();
  final values = await PersistValues.singleton();
  print('PersistValues load ${values.length} items used ${DateTime.now().difference(begin).inMilliseconds} ms');
  begin = DateTime.now();

  values.clear();

  for (int i = 0; i < kCount; i++) {
    values.setInt(i.toString(), i);
  }
  for (int i = kCount; i < kCount2; i++) {
    values.setString(i.toString(), i.toString());
  }
  final list = List<String>(kCount);
  for (int i = 0; i < list.length; i++)
    list[i] = i.toString();
  values.setStringList('list', list);

  print('PersistValues write ${values.length} items used ${DateTime.now().difference(begin).inMilliseconds} ms');
}

Future testSharedPreferencesSet() async {
/*  var begin = DateTime.now();
  final pref = await SharedPreferences.getInstance();
  print('SharedPreferences load ${pref.getKeys().length} items used ${DateTime.now().difference(begin).inMilliseconds} ms');
  begin = DateTime.now();

  pref.clear();
  for (int i = 0; i < kCount; i++) {
    pref.setInt(i.toString(), i);
  }
  for (int i = kCount; i < kCount2; i++) {
    pref.setString(i.toString(), i.toString());
  }
  final list = List<String>(kCount);
  for (int i = 0; i < list.length; i++)
    list[i] = i.toString();
  pref.setStringList('list', list);

  print('SharedPreferences write ${pref.getKeys().length} items used ${DateTime.now().difference(begin).inMilliseconds} ms');
*/}
