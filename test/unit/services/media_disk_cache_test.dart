import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/media_disk_cache.dart';

/// path_provider has no implementation in a unit test, so stub the platform
/// channel to hand back a real temp directory. That keeps these tests against
/// the actual filesystem, which is the point - the interesting failures here
/// (partial writes, eviction order, a hostile storage_path) are filesystem
/// behaviour, not logic that a fake would reproduce.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory cacheDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ghostcopy_cache_test');
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    cacheDir = Directory('${root.path}${Platform.pathSeparator}media_cache');
  });

  tearDown(() async {
    await MediaDiskCache.instance.clear();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Uint8List bytes(int length, [int fill = 7]) =>
      Uint8List.fromList(List<int>.filled(length, fill));

  test('round-trips bytes unchanged', () async {
    final data = bytes(1024, 42);
    await MediaDiskCache.instance.put('clips/a.png', data);

    expect(await MediaDiskCache.instance.get('clips/a.png'), data);
  });

  test('misses cleanly for an unknown path', () async {
    expect(await MediaDiskCache.instance.get('clips/never-written'), isNull);
  });

  test('a storage path with traversal segments stays inside the cache dir',
      () async {
    // storage_path comes from the database. If it were used to build a
    // filename directly, this would escape the cache directory and overwrite
    // something else - hence the SHA-256 key.
    const hostile = '../../../../evil.bin';
    await MediaDiskCache.instance.put(hostile, bytes(64));

    // Everything written lives in the cache dir under a 64-char hex name.
    final written = cacheDir.listSync().whereType<File>().toList();
    expect(written, hasLength(1));
    expect(
      written.single.uri.pathSegments.last,
      matches(RegExp(r'^[0-9a-f]{64}\.bin$')),
    );
    // It still round-trips; it is simply stored under a hashed name.
    expect(await MediaDiskCache.instance.get(hostile), hasLength(64));
  });

  test('refuses entries above the per-entry ceiling', () async {
    await MediaDiskCache.instance.put(
      'clips/huge',
      bytes(MediaDiskCache.maxEntryBytes + 1),
    );

    expect(await MediaDiskCache.instance.get('clips/huge'), isNull);
  });

  test('prune keeps only the live storage paths', () async {
    await MediaDiskCache.instance.put('clips/keep-1', bytes(32));
    await MediaDiskCache.instance.put('clips/keep-2', bytes(32));
    await MediaDiskCache.instance.put('clips/expired', bytes(32));

    await MediaDiskCache.instance.prune({'clips/keep-1', 'clips/keep-2'});

    expect(await MediaDiskCache.instance.get('clips/keep-1'), isNotNull);
    expect(await MediaDiskCache.instance.get('clips/keep-2'), isNotNull);
    // The server keeps only the 20 most recent clips per user, so bytes for a
    // clip that dropped out of history can never be opened again.
    expect(await MediaDiskCache.instance.get('clips/expired'), isNull);
  });

  test('prune with an empty live set empties the cache', () async {
    await MediaDiskCache.instance.put('clips/a', bytes(32));

    await MediaDiskCache.instance.prune(<String>{});

    expect(await MediaDiskCache.instance.get('clips/a'), isNull);
  });

  test('remove drops a single entry and leaves the rest', () async {
    await MediaDiskCache.instance.put('clips/a', bytes(32));
    await MediaDiskCache.instance.put('clips/b', bytes(32));

    await MediaDiskCache.instance.remove('clips/a');

    expect(await MediaDiskCache.instance.get('clips/a'), isNull);
    expect(await MediaDiskCache.instance.get('clips/b'), isNotNull);
  });

  test('clear empties the cache, as sign-out requires', () async {
    await MediaDiskCache.instance.put('clips/a', bytes(32));
    await MediaDiskCache.instance.put('clips/b', bytes(32));

    await MediaDiskCache.instance.clear();

    expect(await MediaDiskCache.instance.currentBytes(), 0);
  });

  test('a zero-length file reads as a miss and is cleaned up', () async {
    // Simulates a write interrupted by a crash or a full disk.
    await MediaDiskCache.instance.put('clips/a', bytes(32));
    final files = cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bin'))
        .toList();
    expect(files, hasLength(1));
    await files.single.writeAsBytes(<int>[]);

    expect(await MediaDiskCache.instance.get('clips/a'), isNull);
    expect(files.single.existsSync(), isFalse);
  });

  test('a partial write never becomes a visible cache entry', () async {
    // put() writes to <name>.tmp and renames, so a leftover .tmp must not be
    // served, and prune must not treat it as an expired entry to delete.
    await MediaDiskCache.instance.put('clips/a', bytes(32));
    final stray = File('${cacheDir.path}${Platform.pathSeparator}abc.bin.tmp');
    await stray.writeAsBytes(bytes(16));

    await MediaDiskCache.instance.prune(<String>{});

    expect(stray.existsSync(), isTrue);
  });
}
