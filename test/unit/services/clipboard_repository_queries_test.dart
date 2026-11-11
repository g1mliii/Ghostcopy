import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late ClipboardRepository repository;
  late _Encryption encryption;
  late List<http.Request> requests;
  late List<int> rows;
  late bool failCount;

  setUp(() async {
    requests = [];
    failCount = false;
    rows = List.generate(265, (index) => 265 - index);
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (failCount) {
          return http.Response(
            jsonEncode({'message': 'Count unavailable', 'code': '42501'}),
            403,
            request: request,
          );
        }
        final query = request.url.queryParameters;
        if (request.method == 'DELETE') {
          final ids = query['id']!
              .substring(4, query['id']!.length - 1)
              .split(',')
              .map(int.parse)
              .toSet();
          expect(ids.length, lessThanOrEqualTo(100));
          rows.removeWhere(ids.contains);
          return http.Response('', 204, request: request);
        }
        final offset = int.parse(query['offset'] ?? '0');
        final limit = int.parse(query['limit'] ?? '1000');
        return http.Response(
          jsonEncode(
            rows.skip(offset).take(limit).map((id) => {'id': id}).toList(),
          ),
          200,
          headers: {
            'content-range': rows.isEmpty
                ? '*/0'
                : '0-${rows.length - 1}/${rows.length}',
          },
          request: request,
        );
      }),
    );
    final expiry =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    final jwt = base64Url
        .encode(utf8.encode(jsonEncode({'sub': 'user', 'exp': expiry})))
        .replaceAll('=', '');
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'e30.$jwt.signature',
        'refresh_token': 'refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': expiry,
        'user': {
          'id': 'user',
          'aud': 'authenticated',
          'created_at': '2026-01-01',
          'app_metadata': <String, Object?>{},
          'user_metadata': <String, Object?>{},
        },
      }),
    );
    encryption = _Encryption();
    repository = ClipboardRepository(
      client: client,
      encryptionService: encryption,
      storageService: _Storage(),
    );
  });

  tearDown(() async {
    repository.dispose();
    await client.dispose();
  });

  test(
    'encryption initialization failure prevents plaintext uploads',
    () async {
      when(
        () => encryption.initialize('user'),
      ).thenThrow(SecurityException('Keychain unavailable'));
      final item = ClipboardItem(
        id: '',
        userId: 'user',
        deviceType: 'ios',
        content: 'private clip',
        createdAt: DateTime.now(),
      );

      await expectLater(
        repository.insert(item),
        throwsA(isA<SecurityException>()),
      );

      expect(requests, isEmpty);
      verifyNever(encryption.isEnabled);
    },
  );

  test(
    'clipboard count failures cannot be mistaken for an empty account',
    () async {
      failCount = true;
      await expectLater(
        repository.getClipboardCountForCurrentUser(),
        throwsA(isA<RepositoryException>()),
      );
    },
  );

  test(
    'clipboard count reports saved clips and genuinely empty accounts',
    () async {
      expect(await repository.getClipboardCountForCurrentUser(), 265);
      rows.clear();
      expect(await repository.getClipboardCountForCurrentUser(), 0);
    },
  );

  test(
    'idle polling selects only one ID and never initializes encryption',
    () async {
      expect(await repository.getLatestItemId(), '265');
      final query = requests.single.url.queryParameters;
      expect(query['select'], 'id');
      expect(query['limit'], '1');
      expect(query['user_id'], 'eq.user');
      verifyNever(() => encryption.initialize(any()));
    },
  );

  test(
    'retention deletes bounded pages until only the newest 15 remain',
    () async {
      await repository.cleanupOldItems();
      expect(rows, List.generate(15, (index) => 265 - index));
      expect(requests.where((request) => request.method == 'DELETE').length, 3);
      for (final request in requests.where(
        (request) => request.method == 'GET',
      )) {
        expect(request.url.queryParameters['offset'], '15');
        expect(request.url.queryParameters['limit'], '100');
      }
    },
  );
}
