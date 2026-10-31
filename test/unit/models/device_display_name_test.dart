import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/device.dart';

/// Phones register as `name · 8 hex chars` so the unique index on the name
/// holds when two share one. People should see only the name.
void main() {
  Device device(String type, String? name) => Device(
    id: '1',
    userId: 'u1',
    deviceType: type,
    deviceName: name,
    lastActive: DateTime.utc(2026),
    createdAt: DateTime.utc(2026),
  );

  test('drops the uniqueness suffix', () {
    // iOS: identifierForVendor, upper case. Android: install id, lower case.
    expect(
      device('ios', "Subaig's iPhone · 1A2B3C4D").displayName,
      "Subaig's iPhone",
    );
    expect(device('android', 'Pixel 8 · 0f9e8d7c').displayName, 'Pixel 8');
  });

  test('leaves names without one alone', () {
    expect(
      device('macos', 'Subaigs-MacBook-Pro').displayName,
      'Subaigs-MacBook-Pro',
    );
    // A middle dot the user typed themselves, not followed by an id.
    expect(device('windows', 'Work · Desk').displayName, 'Work · Desk');
    expect(device('ios', 'Phone · ABCDEFGH').displayName, 'Phone · ABCDEFGH');
  });

  test('preserves desktop names ending in eight hex characters', () {
    for (final type in ['windows', 'macos', 'linux']) {
      expect(
        device(type, 'Office · DEADBEEF').displayName,
        'Office · DEADBEEF',
      );
    }
  });

  test('falls back to the platform when there is no name left', () {
    expect(device('ios', null).displayName, 'iOS');
    expect(device('android', ' · 0f9e8d7c').displayName, 'Android');
  });
}
