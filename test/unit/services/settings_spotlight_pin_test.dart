import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/spotlight_pin.dart';
import 'package:ghostcopy/services/impl/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SettingsService> settingsWith(Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    final settings = SettingsService();
    await settings.initialize();
    return settings;
  }

  test('nothing saved is unpinned', () async {
    expect(await (await settingsWith({})).getSpotlightPin(), SpotlightPin.off);
  });

  test('each pin round-trips', () async {
    final settings = await settingsWith({});
    for (final pin in SpotlightPin.values) {
      await settings.setSpotlightPin(pin);
      expect(await settings.getSpotlightPin(), pin);
    }
  });

  test("1.0.7's pin was always on top, and stays that way", () async {
    final settings = await settingsWith({'flutter.spotlight_pinned': true});
    expect(await settings.getSpotlightPin(), SpotlightPin.onTop);
  });

  test('a choice made since outranks the old pin', () async {
    final settings = await settingsWith({
      'flutter.spotlight_pinned': true,
      'flutter.spotlight_pin': 'open',
    });
    expect(await settings.getSpotlightPin(), SpotlightPin.open);
  });
}
