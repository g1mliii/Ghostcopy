import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/media_memory_cache.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide StorageException;

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

ClipboardItem _fileClip(String path) => ClipboardItem(
  id: 'clip',
  userId: 'user',
  content: '',
  deviceType: 'windows',
  createdAt: DateTime(2026),
  contentType: ContentType.filePdf,
  storagePath: path,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaMemoryCache.instance.clear();
  });

  test('an offline storage download is a NetworkException', () async {
    // Offline, the edge function call throws http's ClientException. It used
    // to be folded into a StorageException, and "no connection" was lost.
    final storage = StorageService(
      client: SupabaseClient(
        'https://example.com',
        'anon-key',
        httpClient: MockClient(
          (_) => throw http.ClientException('Failed host lookup'),
        ),
      ),
    );

    await expectLater(
      storage.downloadFile('user/clip/file'),
      throwsA(isA<NetworkException>()),
    );
  });

  test('the repository remembers a download that failed offline', () async {
    const path = 'user/offline/file';
    final storage = _Storage();
    final repository = ClipboardRepository(
      client: SupabaseClient('https://example.com', 'anon-key'),
      encryptionService: _Encryption(),
      storageService: storage,
    );
    addTearDown(repository.dispose);
    final clip = _fileClip(path);

    when(
      () => storage.downloadFile(path),
    ).thenThrow(NetworkException('offline'));
    expect(await repository.downloadFile(clip), isNull);
    expect(repository.lastDownloadWasOffline(clip), isTrue);

    // Back online: the same clip downloads, and is no longer marked.
    when(
      () => storage.downloadFile(path),
    ).thenAnswer((_) async => Uint8List.fromList([1, 2, 3]));
    expect(await repository.downloadFile(clip), isNotNull);
    expect(repository.lastDownloadWasOffline(clip), isFalse);
  });

  test('a download the server refused is not reported as offline', () async {
    const path = 'user/refused/file';
    final storage = _Storage();
    final repository = ClipboardRepository(
      client: SupabaseClient('https://example.com', 'anon-key'),
      encryptionService: _Encryption(),
      storageService: storage,
    );
    addTearDown(repository.dispose);
    final clip = _fileClip(path);

    when(
      () => storage.downloadFile(path),
    ).thenThrow(StorageException('R2 download failed with status 404'));
    expect(await repository.downloadFile(clip), isNull);
    expect(repository.lastDownloadWasOffline(clip), isFalse);
  });
}
