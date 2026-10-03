import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/packaged_app_data.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('forFamilyName', () {
    test("is the package's LocalState and LocalCache", () {
      final data = PackagedAppData.forFamilyName(
        'g1mli.GhostCopy_41asz506sbn22',
        localAppData: p.join('C:', 'Users', 'sam', 'AppData', 'Local'),
      )!;
      final root = p.join(
        'C:',
        'Users',
        'sam',
        'AppData',
        'Local',
        'Packages',
        'g1mli.GhostCopy_41asz506sbn22',
      );
      expect(data.localState, p.join(root, 'LocalState'));
      expect(data.localCache, p.join(root, 'LocalCache'));
    });

    test('is null without a package or a LOCALAPPDATA', () {
      expect(PackagedAppData.forFamilyName(null, localAppData: 'x'), isNull);
      expect(PackagedAppData.forFamilyName('', localAppData: 'x'), isNull);
      expect(PackagedAppData.forFamilyName('pkg', localAppData: null), isNull);
    });
  });

  group('moveFromAppData', () {
    late Directory home;
    late Map<String, String> env;
    late PackagedAppData data;

    String roaming(String rel) =>
        p.join(env['APPDATA']!, 'com.ghostcopy', 'ghostcopy', rel);
    String local(String rel) =>
        p.join(env['LOCALAPPDATA']!, 'com.ghostcopy', 'ghostcopy', rel);

    void write(String path, String content) => File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

    setUp(() {
      home = Directory.systemTemp.createTempSync('packaged');
      addTearDown(() => home.deleteSync(recursive: true));
      env = {
        'APPDATA': p.join(home.path, 'Roaming'),
        'LOCALAPPDATA': p.join(home.path, 'Local'),
      };
      data = PackagedAppData.forFamilyName(
        'pkg',
        localAppData: env['LOCALAPPDATA'],
      )!;
    });

    test('support data goes to LocalState, caches to LocalCache', () async {
      write(roaming('shared_preferences.json'), '{"signed":"in"}');
      write(roaming('single_instance.secret'), 'secret');
      write(roaming(p.join('media', 'a.bin')), 'media');
      write(local(p.join('history', 'page.json')), 'history');
      write(
        p.join(env['LOCALAPPDATA']!, 'GhostCopy', 'sentry-native', 'run'),
        'crash',
      );

      await data.moveFromAppData(env);

      String state(String rel) =>
          File(p.join(data.localState, rel)).readAsStringSync();
      String cache(String rel) =>
          File(p.join(data.localCache, rel)).readAsStringSync();
      expect(state('shared_preferences.json'), '{"signed":"in"}');
      expect(state('single_instance.secret'), 'secret');
      expect(state(p.join('media', 'a.bin')), 'media');
      expect(cache(p.join('history', 'page.json')), 'history');
      expect(cache(p.join('sentry-native', 'run')), 'crash');
    });

    test('leaves nothing of GhostCopy in AppData', () async {
      write(roaming('shared_preferences.json'), '{}');
      write(local('cache.bin'), 'x');
      write(
        p.join(env['LOCALAPPDATA']!, 'GhostCopy', 'sentry-native', 'run'),
        'crash',
      );

      await data.moveFromAppData(env);

      expect(
        Directory(p.join(env['APPDATA']!, 'com.ghostcopy')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(env['LOCALAPPDATA']!, 'com.ghostcopy')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(env['LOCALAPPDATA']!, 'GhostCopy')).existsSync(),
        isFalse,
      );
    });

    // The package's copy is the one the app has been using; an AppData copy
    // of the same file is older, or another build's.
    test('what the package already has wins', () async {
      write(roaming('shared_preferences.json'), 'old');
      write(p.join(data.localState, 'shared_preferences.json'), 'current');

      await data.moveFromAppData(env);

      expect(
        File(
          p.join(data.localState, 'shared_preferences.json'),
        ).readAsStringSync(),
        'current',
      );
      expect(File(roaming('shared_preferences.json')).existsSync(), isFalse);
    });

    // A copy across volumes interrupted part way leaves a folder in the
    // package missing some of its files. Taking it as whole, and deleting
    // the original, lost those files for good.
    test('a folder already in the package is completed, not trusted', () async {
      write(roaming(p.join('secure', 'a.dat')), 'a');
      write(roaming(p.join('secure', 'b.dat')), 'b');
      write(p.join(data.localState, 'secure', 'a.dat'), 'a');

      await data.moveFromAppData(env);

      expect(
        File(p.join(data.localState, 'secure', 'b.dat')).readAsStringSync(),
        'b',
      );
      expect(Directory(roaming('secure')).existsSync(), isFalse);
    });

    // All or nothing: the app runs from AppData until everything is across,
    // so a half-done move must leave AppData whole, not split between the two.
    test('a move that cannot finish puts back what it moved', () async {
      write(roaming('shared_preferences.json'), '{"signed":"in"}');
      write(roaming('flutter_secure_storage.dat'), 'secret');
      // A file where the package has a folder of the same name cannot move.
      write(roaming('media'), 'a file');
      Directory(p.join(data.localState, 'media')).createSync(recursive: true);

      expect(await data.moveFromAppData(env), isFalse);

      expect(
        File(roaming('shared_preferences.json')).readAsStringSync(),
        '{"signed":"in"}',
      );
      expect(File(roaming('flutter_secure_storage.dat')).existsSync(), isTrue);
      expect(File(roaming('media')).existsSync(), isTrue);
      expect(
        File(p.join(data.localState, 'shared_preferences.json')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(data.localState, '.moved_from_appdata')).existsSync(),
        isFalse,
      );
    });

    test('happens once', () async {
      write(roaming('a.json'), 'first');
      await data.moveFromAppData(env);

      // Something writes to AppData afterwards - an unpackaged build, say.
      write(roaming('b.json'), 'later');
      await data.moveFromAppData(env);

      expect(File(roaming('b.json')).existsSync(), isTrue);
      expect(File(p.join(data.localState, 'b.json')).existsSync(), isFalse);
    });

    test('with nothing in AppData, does nothing but mark it done', () async {
      expect(await data.moveFromAppData(env), isTrue);

      // The marker, and the lock that kept other processes out meanwhile.
      expect(
        Directory(data.localState).listSync().map((e) => p.basename(e.path)),
        unorderedEquals(['.moved_from_appdata', '.moving.lock']),
      );
      expect(
        Directory(p.join(env['APPDATA']!, 'com.ghostcopy')).existsSync(),
        isFalse,
      );
    });
  });

  // shared_preferences' Windows backends build their own path provider, so
  // replacing path_provider's alone left the session and settings in
  // AppData - the file the move had just emptied.
  test('preferences inside a package live in LocalState', () async {
    final home = Directory.systemTemp.createTempSync('prefs');
    addTearDown(() => home.deleteSync(recursive: true));
    final data = PackagedAppData.forFamilyName('pkg', localAppData: home.path)!;

    PackagedAppData.install(data);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session', 'signed-in');
    await SharedPreferencesAsync().setString('async', 'kept');

    final stored = File(p.join(data.localState, 'shared_preferences.json'));
    expect(stored.readAsStringSync(), contains('signed-in'));
    expect(stored.readAsStringSync(), contains('kept'));
  });

  test('path_provider inside a package uses its folders', () async {
    final home = Directory.systemTemp.createTempSync('provider');
    addTearDown(() => home.deleteSync(recursive: true));
    final data = PackagedAppData.forFamilyName('pkg', localAppData: home.path)!;
    final provider = PackagedPathProvider(data);

    expect(await provider.getApplicationSupportPath(), data.localState);
    expect(await provider.getApplicationCachePath(), data.localCache);
    expect(Directory(data.localState).existsSync(), isTrue);
  });
}
