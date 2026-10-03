import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/packaged_app_data.dart';
import 'package:ghostcopy/services/temp_file_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

    test(
      'deletions in live AppData remove destination-only remnants',
      () async {
        write(roaming('shared_preferences.json'), 'live session');
        write(roaming('media_cache/kept.bin'), 'live media');
        write(local('history/kept.json'), 'live history');
        write(crashDb('kept'), 'live crash');
        write(state('shared_preferences.json').path, 'stale session');
        write(state('media_cache/kept.bin').path, 'stale media');
        write(state('media_cache/deleted.bin').path, 'deleted media');
        write(state('removed_folder/secret.bin').path, 'deleted folder');
        write(cache('history/deleted.json').path, 'deleted history');
        write(cache('sentry-native/kept').path, 'stale crash');
        write(cache('sentry-native/deleted').path, 'deleted crash');

        expect(await data.moveFromAppData(env), isTrue);

        expect(
          state('shared_preferences.json').readAsStringSync(),
          'live session',
        );
        expect(state('media_cache/kept.bin').readAsStringSync(), 'live media');
        expect(cache('history/kept.json').readAsStringSync(), 'live history');
        expect(cache('sentry-native/kept').readAsStringSync(), 'live crash');
        expect(state('media_cache/deleted.bin').existsSync(), isFalse);
        expect(Directory(state('removed_folder').path).existsSync(), isFalse);
        expect(cache('history/deleted.json').existsSync(), isFalse);
        expect(cache('sentry-native/deleted').existsSync(), isFalse);
      },
    );

    test(
      'an absent legacy root does not erase its only package copy',
      () async {
        // An earlier version could rename a whole root before failing to
        // commit. Its absence alone is not evidence that its data was deleted.
        write(state('shared_preferences.json').path, 'only session');
        write(cache('sentry-native/run').path, 'only crash');
        write(local('history/page.json'), 'live history');

        expect(await data.moveFromAppData(env), isTrue);

        expect(
          state('shared_preferences.json').readAsStringSync(),
          'only session',
        );
        expect(cache('sentry-native/run').readAsStringSync(), 'only crash');
        expect(cache('history/page.json').readAsStringSync(), 'live history');
      },
    );

    test('interrupted moves are restored before pruning remnants', () async {
      write(roaming('shared_preferences.json'), 'updated session');
      write(state('shared_preferences.json').path, 'stale session');
      write(state('secure/passphrase.dat').path, 'only passphrase');
      write(state('deleted.bin').path, 'deleted while using AppData');
      write(
        state('.moving_files.json').path,
        jsonEncode([
          [
            roaming('shared_preferences.json'),
            state('shared_preferences.json').path,
          ],
          [
            roaming('secure/passphrase.dat'),
            state('secure/passphrase.dat').path,
          ],
        ]),
      );

      expect(await data.moveFromAppData(env), isTrue);

      expect(
        state('shared_preferences.json').readAsStringSync(),
        'updated session',
      );
      expect(
        state('secure/passphrase.dat').readAsStringSync(),
        'only passphrase',
      );
      expect(state('deleted.bin').existsSync(), isFalse);
    });

    test('recovery paths cannot leave the legacy and package roots', () async {
      final unrelated = p.join(env['APPDATA']!, 'unrelated.txt');
      write(unrelated, 'unrelated');
      write(roaming('shared_preferences.json'), 'session');
      write(
        state('.moving_files.json').path,
        jsonEncode([
          [unrelated, state('shared_preferences.json').path],
        ]),
      );

      await expectLater(
        data.moveFromAppData(env),
        throwsA(isA<PackagedAppDataRecoveryException>()),
      );

      expect(File(unrelated).readAsStringSync(), 'unrelated');
      expect(
        File(roaming('shared_preferences.json')).readAsStringSync(),
        'session',
      );
      expect(state('.moved_from_appdata').existsSync(), isFalse);
    });

    test(
      'a locked stale remnant aborts before moving any live files',
      () async {
        write(roaming('shared_preferences.json'), 'session');
        write(state('deleted.bin').path, 'stale');
        final release = _holdWithoutDeleteSharing(state('deleted.bin').path);
        try {
          expect(await data.moveFromAppData(env), isFalse);
          expect(
            File(roaming('shared_preferences.json')).readAsStringSync(),
            'session',
          );
          expect(state('.moved_from_appdata').existsSync(), isFalse);
        } finally {
          release();
        }

        expect(await data.moveFromAppData(env), isTrue);
        expect(state('deleted.bin').existsSync(), isFalse);
        expect(state('shared_preferences.json').readAsStringSync(), 'session');
      },
      skip: !Platform.isWindows,
    );

    for (final lateFile in ['late.json', 'shared_preferences.json']) {
      test(
        'a late write to $lateFile aborts commit without losing data',
        () async {
          write(roaming('shared_preferences.json'), 'original session');
          write(local('cache.bin'), 'cache');

          expect(
            await data.moveFromAppData(
              env,
              beforeCommit: () async => write(roaming(lateFile), 'late update'),
            ),
            isFalse,
          );

          expect(File(roaming(lateFile)).readAsStringSync(), 'late update');
          expect(
            File(roaming('shared_preferences.json')).readAsStringSync(),
            lateFile == 'shared_preferences.json'
                ? 'late update'
                : 'original session',
          );
          expect(File(local('cache.bin')).readAsStringSync(), 'cache');
          expect(state('.moved_from_appdata').existsSync(), isFalse);

          expect(await data.moveFromAppData(env), isTrue);
          expect(state(lateFile).readAsStringSync(), 'late update');
        },
      );
    }

    test(
      'an incomplete rollback stops startup until recovery succeeds',
      () async {
        write(roaming('shared_preferences.json'), 'original session');
        write(local('cache.bin'), 'cache');
        final originalProvider = PathProviderPlatform.instance;
        final originalInUse = PackagedAppData.inUse;
        final blocker = Directory(state('.moved_from_appdata.partial').path);
        void Function()? release;
        try {
          await expectLater(
            PackagedAppData.prepareForData(
              data,
              env,
              beforeCommit: () async {
                release = _holdWithoutDeleteSharing(
                  state('shared_preferences.json').path,
                  blockReads: true,
                );
                blocker.createSync();
              },
            ),
            throwsA(isA<PackagedAppDataRecoveryException>()),
          );

          expect(PathProviderPlatform.instance, same(originalProvider));
          expect(PackagedAppData.inUse, same(originalInUse));
          expect(
            File(roaming('shared_preferences.json')).existsSync(),
            isFalse,
          );
          expect(state('.moving_files.json').existsSync(), isTrue);
          expect(state('.moved_from_appdata').existsSync(), isFalse);
        } finally {
          release?.call();
        }

        blocker.deleteSync();
        await PackagedAppData.prepareForData(data, env);

        expect(PackagedAppData.inUse, same(data));
        expect(
          state('shared_preferences.json').readAsStringSync(),
          'original session',
        );
        expect(cache('cache.bin').readAsStringSync(), 'cache');
        expect(state('.moved_from_appdata').existsSync(), isTrue);
        expect(state('.moving_files.json').existsSync(), isFalse);
      },
      skip: !Platform.isWindows,
    );

    test(
      'a link moves without following or deleting its external target',
      () async {
        write(roaming('shared_preferences.json'), 'session');
        final external = Directory(p.join(env['APPDATA']!, 'user_owned'))
          ..createSync();
        write(p.join(external.path, 'payload.bin'), 'user data');
        final link = Link(roaming('linked_cache'));
        if (Platform.isWindows) {
          // Junctions require no symbolic-link privilege on Windows.
          final result = await Process.run('cmd.exe', [
            '/c',
            'mklink',
            '/J',
            link.path,
            external.path,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout} ${result.stderr}',
          );
        } else {
          await link.create(external.path);
        }

        expect(await data.moveFromAppData(env), isTrue);

        expect(link.existsSync(), isFalse);
        expect(Link(state('linked_cache').path).existsSync(), isTrue);
        expect(
          File(p.join(external.path, 'payload.bin')).readAsStringSync(),
          'user data',
        );
        expect(state('shared_preferences.json').readAsStringSync(), 'session');
      },
    );

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

    for (final blocked in [
      '.moved_from_appdata',
      '.moved_from_appdata.partial',
    ]) {
      test('a blocked $blocked rolls back all data and can retry', () async {
        write(roaming('shared_preferences.json'), 'session');
        write(roaming('secure/passphrase.dat'), 'passphrase');
        write(local('history/page.json'), 'history');
        write(crashDb('run'), 'crash');
        final blocker = Directory(state(blocked).path)
          ..createSync(recursive: true);

        expect(await data.moveFromAppData(env), isFalse);

        expect(
          File(roaming('shared_preferences.json')).readAsStringSync(),
          'session',
        );
        expect(
          File(roaming('secure/passphrase.dat')).readAsStringSync(),
          'passphrase',
        );
        expect(File(local('history/page.json')).readAsStringSync(), 'history');
        expect(File(crashDb('run')).readAsStringSync(), 'crash');
        expect(state('.moved_from_appdata').existsSync(), isFalse);

        // The fallback app can update AppData before the next attempt.
        write(roaming('shared_preferences.json'), 'updated session');
        blocker.deleteSync();
        expect(await data.moveFromAppData(env), isTrue);
        expect(
          state('shared_preferences.json').readAsStringSync(),
          'updated session',
        );
        expect(state('secure/passphrase.dat').readAsStringSync(), 'passphrase');
        expect(cache('history/page.json').readAsStringSync(), 'history');
        expect(cache('sentry-native/run').readAsStringSync(), 'crash');
      });
    }

    test(
      'a locked cache file leaves every original intact and can retry',
      () async {
        write(roaming('shared_preferences.json'), 'session');
        write(local('media_cache/a.bin'), 'first');
        write(local('media_cache/b.bin'), 'second');
        write(local('media_cache/z.bin'), 'locked');
        final release = _holdWithoutDeleteSharing(local('media_cache/z.bin'));
        try {
          expect(await data.moveFromAppData(env), isFalse);

          expect(
            File(roaming('shared_preferences.json')).readAsStringSync(),
            'session',
          );
          for (final (name, content) in [
            ('a.bin', 'first'),
            ('b.bin', 'second'),
            ('z.bin', 'locked'),
          ]) {
            expect(
              File(local('media_cache/$name')).readAsStringSync(),
              content,
            );
          }
          expect(state('.moved_from_appdata').existsSync(), isFalse);
        } finally {
          release();
        }

        expect(await data.moveFromAppData(env), isTrue);
        expect(cache('media_cache/a.bin').readAsStringSync(), 'first');
        expect(cache('media_cache/b.bin').readAsStringSync(), 'second');
        expect(cache('media_cache/z.bin').readAsStringSync(), 'locked');
        expect(Directory(local('media_cache')).existsSync(), isFalse);
      },
      skip: !Platform.isWindows,
    );

    // On a clean profile an earlier package's AppData writes were virtualized
    // into these very folders - the data being migrated, seen from the other
    // side. Reconciled as remnants, they were deleted before the move began.
    test("Windows' own LocalCache folders are not remnants", () async {
      write(local('cache.bin'), 'x');
      for (final own in ['Local', 'Roaming', 'Temp']) {
        write(cache(p.join(own, 'kept.txt')).path, own);
      }

      expect(await data.moveFromAppData(env), isTrue);

      for (final own in ['Local', 'Roaming', 'Temp']) {
        expect(
          cache(p.join(own, 'kept.txt')).readAsStringSync(),
          own,
          reason: own,
        );
      }
    });

    // Temp files now go under the package, and only there is swept, so an
    // earlier version's - decrypted downloads - would outlive an uninstall.
    test("an earlier version's temp files are swept once it commits", () async {
      final temp = Directory(p.join(env['LOCALAPPDATA']!, 'Temp'))
        ..createSync(recursive: true);
      env['TEMP'] = temp.path;
      write(p.join(temp.path, 'ghostcopy_123_notes.txt'), 'plaintext');
      write(p.join(temp.path, 'other_app.tmp'), 'not ours');

      expect(await data.moveFromAppData(env), isTrue);

      expect(
        File(p.join(temp.path, 'ghostcopy_123_notes.txt')).existsSync(),
        isFalse,
      );
      expect(File(p.join(temp.path, 'other_app.tmp')).existsSync(), isTrue);
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

      // Only the marker and lock remain after a committed migration.
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

  test('downloaded temporary plaintext stays inside the package', () async {
    PackagedAppData.install(data);
    final service = TempFileService(clipboardFile: () async => null);

    final file = await service.saveTempFile(
      Uint8List.fromList([1, 2, 3]),
      'decrypted.txt',
    );
    addTearDown(() async {
      if (file.existsSync()) await file.delete();
    });

    expect(p.isWithin(data.localCache, file.path), isTrue);
    expect(p.dirname(file.path), p.join(data.localCache, 'Temp'));
    expect(await file.readAsBytes(), [1, 2, 3]);
  });
}

/// Keep [path] readable and writable, but prevent renaming or deleting it.
/// With [blockReads], deny other access as well to reproduce a failed restore.
void Function() _holdWithoutDeleteSharing(
  String path, {
  bool blockReads = false,
}) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final createFile = kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  final closeHandle = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final name = path.toNativeUtf16();
  const genericRead = 0x80000000;
  const shareReadAndWrite = 3; // FILE_SHARE_READ | FILE_SHARE_WRITE
  const openExisting = 3;
  const normalAttributes = 0x80;
  late final Pointer<Void> handle;
  try {
    handle = createFile(
      name,
      genericRead,
      blockReads ? 0 : shareReadAndWrite,
      nullptr,
      openExisting,
      normalAttributes,
      nullptr,
    );
  } finally {
    calloc.free(name);
  }
  expect(handle, isNot(Pointer<Void>.fromAddress(-1)));
  return () => expect(closeHandle(handle), isNot(0));
}
