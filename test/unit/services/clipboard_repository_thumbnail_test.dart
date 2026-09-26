import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/media_memory_cache.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A history list builds one thumbnail per tile. Going through downloadFile
  // left every full-size image in the RAM cache as well, for the single
  // decode each one was needed for - filling it and evicting what was really
  // on screen.
  testWidgets('building a thumbnail keeps only the thumbnail in RAM', (
    tester,
  ) async {
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    const path = 'thumb-test/large.png';
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 1200, height: 900)),
    );
    final storage = _Storage();
    when(() => storage.downloadFile(path)).thenAnswer((_) async => png);
    final client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: storage,
    );
    addTearDown(repository.dispose);
    final item = ClipboardItem(
      id: '1',
      userId: 'user',
      content: '',
      deviceType: 'windows',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: path,
    );

    final thumbnail = await tester.runAsync(
      () => repository.loadThumbnail(item),
    );

    expect(thumbnail, isNotNull);
    expect(thumbnail!.length, lessThan(png.length));
    expect(cache.get('thumb:$path'), isNotNull);
    expect(cache.get(path), isNull);
  });

  group('thumbnailTargetSize', () {
    // Capping only the width let a full-page screenshot through at 512x9481 -
    // a multi-megabyte "thumbnail" - and upscaled every small icon to 512.
    test('caps the longest edge of a tall image', () {
      final size = ClipboardRepository.thumbnailTargetSize(1080, 20000);
      expect(size.width, isNull);
      expect(size.height, 512);
    });

    test('caps the longest edge of a wide image', () {
      final size = ClipboardRepository.thumbnailTargetSize(6000, 400);
      expect(size.width, 512);
      expect(size.height, isNull);
    });

    test('never scales a small image up', () {
      final size = ClipboardRepository.thumbnailTargetSize(64, 64);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });

    test('leaves an image already at the limit alone', () {
      final size = ClipboardRepository.thumbnailTargetSize(512, 300);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });
  });
}
