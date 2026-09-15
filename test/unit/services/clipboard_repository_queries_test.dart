import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

  setUp(() async {
    requests = [];
    rows = List.generate(265, (index) => 265 - index);
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
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
