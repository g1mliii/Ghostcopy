import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/history_disk_cache.dart';

/// Against the real filesystem, with path_provider's channel stubbed to hand
/// back temp directories - one per kind, so a test can tell which was used.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory support;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ghostcopy_history_test');
    support = Directory('${root.path}${Platform.pathSeparator}support')
      ..createSync();
    cache = Directory('${root.path}${Platform.pathSeparator}cache')
      ..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getApplicationCacheDirectory' => cache.path,
            _ => support.path,
          },
        );
  });

  tearDown(() async {
    await HistoryDiskCache.instance.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final store = HistoryDiskCache.instance;

  Map<String, dynamic> row(int id, [String content = 'clip']) => {
    'id': id,
    'user_id': 'user-a',
    'content': content,
    'device_type': 'windows',
    'is_encrypted': false,
    'created_at': '2026-09-27T12:00:0${id % 10}Z',
    'target_device_type': ['ios'],
  };

  Directory historyDir(Directory base) =>
      Directory('${base.path}${Platform.pathSeparator}history');

  test('rows come back exactly as they were saved', () async {
    await store.save('user-a', [row(2), row(1)]);

    expect(await store.load('user-a'), [row(2), row(1)]);
  });

  test('a save replaces the previous one', () async {
    await store.save('user-a', [row(1)]);
    await store.save('user-a', [row(3), row(2)]);

    expect((await store.load('user-a')).map((r) => r['id']), [3, 2]);
  });

  // Signing in as someone else must never show them the last account's clips,
  // even if the clear on sign-out did not run.
  test("another user's saved rows are not returned", () async {
    await store.save('user-a', [row(1)]);

    expect(await store.load('user-b'), isEmpty);
  });

  // Stored in the cache directory, like thumbnails: application support is
  // swept into device backups, and this may be plaintext.
  test('history lives in the cache directory, not app support', () async {
    await store.save('user-a', [row(1)]);

    expect(historyDir(cache).listSync().whereType<File>(), hasLength(1));
    expect(historyDir(support).existsSync(), isFalse);
  });

  test('remove drops one clip and keeps the rest', () async {
    await store.save('user-a', [row(3), row(2), row(1)]);

    await store.remove('2');

    expect((await store.load('user-a')).map((r) => r['id']), [3, 1]);
  });

  test('clear leaves nothing to load', () async {
    await store.save('user-a', [row(1)]);

    await store.clear();

    expect(await store.load('user-a'), isEmpty);
  });

  // The ordering guarantee: a save that was already queued when sign-out
  // cleared the store must not land afterwards and bring the clips back.
  test('a save queued before a clear does not survive it', () async {
    final saving = store.save('user-a', [row(1)]);
    final clearing = store.clear();
    await Future.wait([saving, clearing]);

    expect(await store.load('user-a'), isEmpty);
  });

  test(
    'large saves preserve snapshots and stay ordered before clear',
    () async {
      final content = 'large clip ' * 10000;
      final metadata = <String, Object?>{
        'tags': ['original'],
      };
      final rows = [row(1, content)..['metadata'] = metadata];
      final saving = store.save('user-a', rows);
      rows.single['content'] = 'changed';
      (metadata['tags']! as List<String>)[0] = 'changed';
      rows.clear();
      await saving;

      final loaded = await store.load('user-a');
      expect(loaded.single['content'], content);
      expect(loaded.single['metadata'], {
        'tags': ['original'],
      });

      final savingAgain = store.save('user-a', [row(2, content)]);
      final clearing = store.clear();
      await Future.wait([savingAgain, clearing]);
      expect(await store.load('user-a'), isEmpty);
    },
  );

  test('a corrupt file reads as empty rather than throwing', () async {
    await store.save('user-a', [row(1)]);
    final file = historyDir(cache).listSync().whereType<File>().single
      ..writeAsStringSync('{"v":1,"user":"user-a","rows":[');

    expect(await store.load('user-a'), isEmpty);
    // And the next save still works over it.
    expect(file.existsSync(), isTrue);
    await store.save('user-a', [row(2)]);
    expect((await store.load('user-a')).map((r) => r['id']), [2]);
  });
}
