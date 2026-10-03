import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/packaged_app_data.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('forFamilyName', () {
    test("is the package's LocalState and LocalCache", () {
      final localAppData = p.join('C:', 'Users', 'sam', 'AppData', 'Local');
      const family = 'g1mli.GhostCopy_41asz506sbn22';

      final data = PackagedAppData.forFamilyName(
        family,
        localAppData: localAppData,
      )!;

      final root = p.join(localAppData, 'Packages', family);
      expect(data.localState, p.join(root, 'LocalState'));
      expect(data.localCache, p.join(root, 'LocalCache'));
    });

    test('is null without a package or a LOCALAPPDATA', () {
      expect(PackagedAppData.forFamilyName(null, localAppData: 'x'), isNull);
      expect(PackagedAppData.forFamilyName('', localAppData: 'x'), isNull);
      expect(PackagedAppData.forFamilyName('pkg', localAppData: null), isNull);
    });
  });

  // A fake user profile: AppData, and a package under it.
  late Map<String, String> env;
  late PackagedAppData data;

  setUp(() {
    final home = Directory.systemTemp.createTempSync('packaged');
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

  String roaming(String rel) =>
      p.join(env['APPDATA']!, 'com.ghostcopy', 'ghostcopy', rel);
  String local(String rel) =>
      p.join(env['LOCALAPPDATA']!, 'com.ghostcopy', 'ghostcopy', rel);
  String crashDb(String rel) => p.join(
    PackagedAppData.unpackagedCrashDatabase(env['LOCALAPPDATA']!),
    rel,
  );
  File state(String rel) => File(p.join(data.localState, rel));
  File cache(String rel) => File(p.join(data.localCache, rel));

  void write(String path, String content) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  group('moveFromAppData', () {
    test('support data goes to LocalState, caches to LocalCache', () async {
      write(roaming('shared_preferences.json'), '{"signed":"in"}');
      write(roaming('single_instance.secret'), 'secret');
      write(roaming(p.join('media', 'a.bin')), 'media');
      write(local(p.join('history', 'page.json')), 'history');
      write(crashDb('run'), 'crash');

      await data.moveFromAppData(env);

      expect(
        state('shared_preferences.json').readAsStringSync(),
        '{"signed":"in"}',
      );
      expect(state('single_instance.secret').readAsStringSync(), 'secret');
      expect(state(p.join('media', 'a.bin')).readAsStringSync(), 'media');
      expect(
        cache(p.join('history', 'page.json')).readAsStringSync(),
        'history',
      );
      expect(cache(p.join('sentry-native', 'run')).readAsStringSync(), 'crash');
    });

    test('leaves nothing of GhostCopy in AppData', () async {
      write(roaming('shared_preferences.json'), '{}');
      write(local('cache.bin'), 'x');
      write(crashDb('run'), 'crash');

      await data.moveFromAppData(env);

      for (final folder in [
        p.join(env['APPDATA']!, 'com.ghostcopy'),
        p.join(env['LOCALAPPDATA']!, 'com.ghostcopy'),
        p.join(env['LOCALAPPDATA']!, 'GhostCopy'),
      ]) {
        expect(Directory(folder).existsSync(), isFalse, reason: folder);
      }
    });

    // Until the move commits the app runs from AppData, so anything already
    // in the package is what a failed attempt left, and the AppData copy is
    // the one the app went on changing. Keeping the remnant rolled back the
    // session or settings to how they were at the failed attempt.
    test('the live AppData copy replaces a remnant in the package', () async {
      write(roaming('shared_preferences.json'), 'changed since');
      write(state('shared_preferences.json').path, 'stale remnant');

      expect(await data.moveFromAppData(env), isTrue);

      expect(
        state('shared_preferences.json').readAsStringSync(),
        'changed since',
      );
      expect(File(roaming('shared_preferences.json')).existsSync(), isFalse);
    });

    // A copy across volumes interrupted part way leaves a folder in the
    // package missing some of its files. Taking it as whole, and deleting
    // the original, lost those files for good.
    test('a folder already in the package is completed, not trusted', () async {
      write(roaming(p.join('secure', 'a.dat')), 'a');
      write(roaming(p.join('secure', 'b.dat')), 'b');
      write(state(p.join('secure', 'a.dat')).path, 'a');

      await data.moveFromAppData(env);

      expect(state(p.join('secure', 'b.dat')).readAsStringSync(), 'b');
      expect(Directory(roaming('secure')).existsSync(), isFalse);
    });

    // All or nothing: the app runs from AppData until everything is across,
    // so a move that cannot finish must leave AppData whole.
    test('a conflict leaves AppData whole and the package unused', () async {
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
      expect(state('shared_preferences.json').existsSync(), isFalse);
      expect(state('.moved_from_appdata').existsSync(), isFalse);
    });

    test('happens once', () async {
      write(roaming('a.json'), 'first');
      await data.moveFromAppData(env);

      // Something writes to AppData afterwards - an unpackaged build, say.
      write(roaming('b.json'), 'later');
      await data.moveFromAppData(env);

      expect(File(roaming('b.json')).existsSync(), isTrue);
      expect(state('b.json').existsSync(), isFalse);
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
    PackagedAppData.install(data);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session', 'signed-in');
    await SharedPreferencesAsync().setString('async', 'kept');

    final stored = state('shared_preferences.json').readAsStringSync();
    expect(stored, contains('signed-in'));
    expect(stored, contains('kept'));
  });

  test('path_provider inside a package uses its folders', () async {
    final provider = PackagedPathProvider(data);

    expect(await provider.getApplicationSupportPath(), data.localState);
    expect(await provider.getApplicationCachePath(), data.localCache);
    expect(Directory(data.localState).existsSync(), isTrue);
  });
}
