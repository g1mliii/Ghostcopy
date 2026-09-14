import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/device.dart';

/// Regression tests for timestamp serialization.
///
/// These values land in Postgres `timestamptz` columns. A LOCAL DateTime
/// serialises with no timezone suffix ("2026-09-13T12:00:00.000"), and Postgres
/// reads a naive timestamp as UTC - so every write was silently shifted by the
/// device's offset. The same mistake in generateMobileLinkToken pushed
/// expires_at past the mobile_link_tokens_max_ttl CHECK east of UTC, and made
/// tokens arrive pre-expired west of it.
void main() {
  // A local wall-clock time, so a missing toUtc() shows up as a naive string.
  final local = DateTime(2026, 9, 13, 12);

  test('ClipboardItem.toJson emits an explicit UTC instant', () {
    final json = ClipboardItem(
      id: '1',
      userId: 'user-1',
      content: 'hello',
      deviceType: 'windows',
      createdAt: local,
    ).toJson();

    final createdAt = json['created_at']! as String;

    expect(
      createdAt.endsWith('Z'),
      isTrue,
      reason:
          'a naive timestamp is reinterpreted as UTC by Postgres: '
          'got "$createdAt"',
    );
    expect(DateTime.parse(createdAt).isAtSameMomentAs(local), isTrue);
  });

  test('Device.toJson emits explicit UTC instants', () {
    final json = Device(
      id: 'd1',
      userId: 'user-1',
      deviceType: 'android',
      lastActive: local,
      createdAt: local,
    ).toJson();

    for (final key in ['last_active', 'created_at']) {
      final value = json[key]! as String;
      expect(value.endsWith('Z'), isTrue, reason: '$key was "$value"');
      expect(DateTime.parse(value).isAtSameMomentAs(local), isTrue);
    }
  });

  test('round-trips back to the same instant', () {
    final json = ClipboardItem(
      id: '1',
      userId: 'user-1',
      content: 'hello',
      deviceType: 'windows',
      createdAt: local,
    ).toJson();

    final parsed = DateTime.parse(json['created_at']! as String);
    expect(parsed.difference(local), Duration.zero);
  });
}
