import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/keychain_accessibility.dart';
import 'package:ghostcopy/services/reinstall_keychain_reset.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<IOSOptions> cleared;

  Future<void> deleteAll(IOSOptions options) async => cleared.add(options);

  setUp(() => cleared = []);

  test('a fresh install clears both places the passphrase lived', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: deleteAll,
    );

    expect(cleared, [passphraseIosOptions, legacyPassphraseIosOptions]);
  });

  // An existing install updating to this version: everything it stored is
  // still its own, passphrase included.
  test('an install that already has preferences is left alone', () async {
    SharedPreferences.setMockInitialValues({'auto_send_enabled': true});
    final prefs = await SharedPreferences.getInstance();

    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: deleteAll,
    );

    expect(cleared, isEmpty);
  });

  test('runs once', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: deleteAll,
    );
    cleared.clear();
    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: deleteAll,
    );

    expect(cleared, isEmpty);
  });

  // The next launch has preferences of its own by then, so without a record
  // that the clear is owed it would look like an upgrade and never retry.
  test('a clear that failed is tried again on the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: (_) async => throw Exception('Keychain locked'),
    );
    await prefs.setBool('auto_send_enabled', false);
    await clearKeychainLeftByEarlierInstall(
      preferences: prefs,
      deleteAll: deleteAll,
    );

    expect(cleared, [passphraseIosOptions, legacyPassphraseIosOptions]);
  });
}
