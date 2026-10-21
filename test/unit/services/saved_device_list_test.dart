import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/device.dart';
import 'package:ghostcopy/services/saved_device_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device list kept between launches so the chips draw before the
/// network answers.
void main() {
  Device device(String id, {String? fcmToken}) => Device(
    id: id,
    userId: 'u1',
    deviceType: 'windows',
    deviceName: 'PC $id',
    fcmToken: fcmToken,
    lastActive: DateTime.utc(2026),
    createdAt: DateTime.utc(2026),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips for the account that saved it', () async {
    await SavedDeviceList.save('u1', [
      device('1'),
      device('2'),
    ], generation: SavedDeviceList.generation);

    final loaded = await SavedDeviceList.load('u1');

    expect(loaded.map((d) => d.id), ['1', '2']);
    expect(loaded.first.deviceName, 'PC 1');
  });

  test('another account reads nothing', () async {
    await SavedDeviceList.save('u1', [
      device('1'),
    ], generation: SavedDeviceList.generation);

    expect(await SavedDeviceList.load('u2'), isEmpty);
  });

  test('push tokens are not written to disk', () async {
    await SavedDeviceList.save('u1', [
      device('1', fcmToken: 'secret-token'),
    ], generation: SavedDeviceList.generation);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('saved_device_list'), isNot(contains('secret')));
    expect((await SavedDeviceList.load('u1')).single.fcmToken, isNull);
  });

  test('clear removes it', () async {
    await SavedDeviceList.save('u1', [
      device('1'),
    ], generation: SavedDeviceList.generation);
    await SavedDeviceList.clear();

    expect(await SavedDeviceList.load('u1'), isEmpty);
  });

  test('a save from a fetch that began before a clear is dropped', () async {
    // The fetch went out signed in as u1...
    final before = SavedDeviceList.generation;
    // ...the user signed out while it was in flight...
    await SavedDeviceList.clear();
    // ...and it came back afterwards.
    await SavedDeviceList.save('u1', [device('1')], generation: before);

    expect(await SavedDeviceList.load('u1'), isEmpty);
  });

  test('a clear asked for after a save lands after it', () async {
    final saving = SavedDeviceList.save('u1', [
      device('1'),
    ], generation: SavedDeviceList.generation);
    final clearing = SavedDeviceList.clear();
    await Future.wait([saving, clearing]);

    expect(await SavedDeviceList.load('u1'), isEmpty);
  });

  test('a corrupt or older entry reads as empty', () async {
    SharedPreferences.setMockInitialValues({'saved_device_list': '{not json'});
    expect(await SavedDeviceList.load('u1'), isEmpty);

    SharedPreferences.setMockInitialValues({
      'saved_device_list': jsonEncode({
        'v': 0,
        'user': 'u1',
        'devices': <Object>[],
      }),
    });
    expect(await SavedDeviceList.load('u1'), isEmpty);
  });
}
