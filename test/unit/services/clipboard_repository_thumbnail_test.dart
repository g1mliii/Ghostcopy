import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/media_memory_cache.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

/// A client signed in as [userId], answering every request with [respond].
Future<SupabaseClient> _signedIn(
  String userId,
  Future<http.Response> Function(http.Request request) respond,
) async {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': userId, 'exp': expires})))
      .replaceAll('=', '');
  final client = SupabaseClient(
    'https://example.com',
    'anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(respond),
  );
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': 'e30.$payload.signature',
      'refresh_token': 'refresh',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': expires,
      'user': {
        'id': userId,
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': '',
        'created_at': '2026-01-01T00:00:00Z',
        'app_metadata': <String, Object?>{},
        'user_metadata': <String, Object?>{},
      },
    }),
  );
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The delete fetches the row first, best effort. When that failed but the
  // delete itself went through, the clip's plaintext thumbnail stayed behind.
  test('a delete cleans the thumbnail even if the lookup failed', () async {
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    const path = 'clips/deleted.png';
    final client = await _signedIn('user', (request) async {
      if (request.method == 'GET') {
        return http.Response('{"message":"timeout"}', 500, request: request);
      }
      if (request.method == 'DELETE') {
        return http.Response(
          jsonEncode([
            {'storage_path': path},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      return http.Response('', 204, request: request);
    });
    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: _Storage(),
    );
    addTearDown(repository.dispose);
    cache.put('thumb:$path', Uint8List.fromList([1, 2, 3]));

    await repository.delete('42');

    expect(cache.get('thumb:$path'), isNull);
  });

  // A launch whose saved session was already dead starts with no user, so the
  // account the caches belonged to is never seen leaving within the run.
  test('caches left by another account are cleared on first sight', () async {
    SharedPreferences.setMockInitialValues({'media_cache_owner': 'old-user'});
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    cache.put('thumb:clips/old.png', Uint8List.fromList([1, 2, 3]));
    final client = await _signedIn(
      'new-guest',
      (request) async => http.Response('', 204, request: request),
    );

    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: _Storage(),
    );
    addTearDown(repository.dispose);
    await pumpEventQueue();

    expect(cache.get('thumb:clips/old.png'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('media_cache_owner'), 'new-guest');
  });

  // The first launch of the version that records an owner: the caches may
  // be a previous account's, and there is no telling whose.
  test('caches with no recorded owner are cleared before claiming', () async {
    SharedPreferences.setMockInitialValues({});
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    cache.put('thumb:clips/legacy.png', Uint8List.fromList([1, 2, 3]));
    final client = await _signedIn(
      'new-guest',
      (request) async => http.Response('', 204, request: request),
    );

    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: _Storage(),
    );
    addTearDown(repository.dispose);
    await pumpEventQueue();

    expect(cache.get('thumb:clips/legacy.png'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('media_cache_owner'), 'new-guest');
  });

  test('the same account keeps its caches across launches', () async {
    SharedPreferences.setMockInitialValues({'media_cache_owner': 'user'});
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    cache.put('thumb:clips/mine.png', Uint8List.fromList([1, 2, 3]));
    final client = await _signedIn(
      'user',
      (request) async => http.Response('', 204, request: request),
    );

    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: _Storage(),
    );
    addTearDown(repository.dispose);
    await pumpEventQueue();

    expect(cache.get('thumb:clips/mine.png'), isNotNull);
  });

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

  // A session Supabase ends by itself - a revoked refresh token - never
  // reached reset(), so the account's cached media, thumbnails included, was
  // left behind for whoever used the machine next.
  test('a session ended outside the app still clears its caches', () async {
    final cache = MediaMemoryCache.instance..clear();
    addTearDown(cache.clear);
    final expires =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    final payload = base64Url
        .encode(utf8.encode(jsonEncode({'sub': 'user', 'exp': expires})))
        .replaceAll('=', '');
    final client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (request) async => http.Response('', 204, request: request),
      ),
    );
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'e30.$payload.signature',
        'refresh_token': 'refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': expires,
        'user': {
          'id': 'user',
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': '',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': <String, Object?>{},
          'user_metadata': <String, Object?>{},
        },
      }),
    );
    final repository = ClipboardRepository(
      client: client,
      encryptionService: _Encryption(),
      storageService: _Storage(),
    );
    addTearDown(repository.dispose);
    cache.put('thumb:clips/a.png', Uint8List.fromList([1, 2, 3]));

    await client.auth.signOut();
    await pumpEventQueue();

    expect(cache.get('thumb:clips/a.png'), isNull);
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
