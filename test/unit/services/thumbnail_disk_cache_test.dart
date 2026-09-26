import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/thumbnail_disk_cache.dart';

/// Against the real filesystem, with path_provider's channel stubbed to hand
/// back temp directories - one per kind, so a test can tell which was used.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory support;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ghostcopy_thumb_test');
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
    await ThumbnailDiskCache.instance.clear();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Uint8List png([int fill = 7]) =>
      Uint8List.fromList(List<int>.filled(256, fill));

  Directory thumbDir(Directory base) =>
      Directory('${base.path}${Platform.pathSeparator}thumbnail_cache');

  // Application support is swept into iOS and Android backups and roams with
  // a Windows profile; these are plaintext previews of possibly encrypted
  // clips, so they belong in the cache directory.
  test('thumbnails live in the cache directory, not app support', () async {
    await ThumbnailDiskCache.instance.put('clips/a.png', png());

    expect(thumbDir(cache).listSync().whereType<File>(), hasLength(1));
    expect(thumbDir(support).existsSync(), isFalse);
  });

  test('a cache left in app support by an older build is removed', () async {
    final legacy = thumbDir(support)..createSync();
    File(
      '${legacy.path}${Platform.pathSeparator}old.png',
    ).writeAsBytesSync(png());

    await ThumbnailDiskCache.instance.put('clips/a.png', png());
    // Removed in the background once the new directory is in use.
    for (var i = 0; i < 50 && legacy.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(legacy.existsSync(), isFalse);
  });

  // A thumbnail write that started just before a delete must not land after
  // the removal meant to follow it.
  test('a removal issued after a write is never overtaken by it', () async {
    final write = ThumbnailDiskCache.instance.put('clips/a.png', png());
    final removal = ThumbnailDiskCache.instance.remove('clips/a.png');
    await Future.wait([write, removal]);

    expect(await ThumbnailDiskCache.instance.get('clips/a.png'), isNull);
  });

  test('a clear issued after a write is never overtaken by it', () async {
    final write = ThumbnailDiskCache.instance.put('clips/a.png', png());
    final clear = ThumbnailDiskCache.instance.clear();
    await Future.wait([write, clear]);

    expect(await ThumbnailDiskCache.instance.get('clips/a.png'), isNull);
  });
}
