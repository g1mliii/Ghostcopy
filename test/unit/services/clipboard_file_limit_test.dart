import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/clipboard_limits.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/impl/encryption_service.dart'
    show encryptFileBytesSync;
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(Uint8List(0)));
  setUp(() {
    SharedPreferences.setMockInitialValues({'media_cache_owner': 'user'});
    CloudConsentService.currentAccessToken = null;
  });
  tearDown(() => CloudConsentService.authorization.value = null);

  test('reserved bytes match the actual AES-GCM file envelope', () {
    final plain = Uint8List.fromList([1, 2, 3]);
    final stored = encryptFileBytesSync(
      plain,
      Uint8List(32),
      nonce: Uint8List(16),
    );
    expect(
      stored.length - plain.length,
      ClipboardLimits.fileEncryptionOverheadBytes,
    );
  });

  for (final encrypted in [false, true]) {
    for (final extra in [0, 1, 32]) {
      test('attachment boundary encrypted=$encrypted extra=$extra', () async {
        CloudConsentService.authorization.value = CloudAuthorization(
          allowed: true,
          parentManaged: encrypted,
          fileSync: true,
          independentAdult: !encrypted,
        );
        var inserts = 0;
        var uploads = 0;
        var encryptions = 0;
        Map<String, Object?>? row;
        final client = SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            inserts++;
            row = jsonDecode(request.body) as Map<String, Object?>;
            expect(
              row!['file_size_bytes'],
              lessThanOrEqualTo(ClipboardLimits.maxFileBytes),
            );
            return http.Response(
              jsonEncode({
                ...row!,
                'id': 'clip',
                'created_at': '2026-11-14T00:00:00Z',
              }),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        addTearDown(client.dispose);
        final expires =
            DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000;
        final payload = base64Url
            .encode(utf8.encode(jsonEncode({'sub': 'user', 'exp': expires})))
            .replaceAll('=', '');
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
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': <String, Object?>{},
              'user_metadata': <String, Object?>{},
            },
          }),
        );
        final encryption = _Encryption();
        when(() => encryption.initialize('user')).thenAnswer((_) async {});
        when(encryption.isEnabled).thenAnswer((_) async => encrypted);
        when(() => encryption.encryptBytes(any())).thenAnswer((call) async {
          encryptions++;
          return Uint8List(
            (call.positionalArguments.single as Uint8List).length +
                ClipboardLimits.fileEncryptionOverheadBytes,
          );
        });
        final storage = _Storage();
        when(
          () => storage.uploadFile(
            userId: any(named: 'userId'),
            clipboardId: any(named: 'clipboardId'),
            bytes: any(named: 'bytes'),
            filename: any(named: 'filename'),
            mimeType: any(named: 'mimeType'),
          ),
        ).thenAnswer((call) async {
          uploads++;
          final bytes = call.namedArguments[#bytes]! as Uint8List;
          expect(bytes.length, lessThanOrEqualTo(ClipboardLimits.maxFileBytes));
          return UploadResult(
            storagePath: 'user/file.pdf',
            fileSizeBytes: bytes.length,
          );
        });
        final repository = ClipboardRepository(
          client: client,
          encryptionService: encryption,
          storageService: storage,
        );
        addTearDown(repository.dispose);
        final bytes = Uint8List(
          ClipboardLimits.maxPlaintextFileBytes(encrypted: encrypted) + extra,
        );
        final sending = repository.insertFile(
          userId: 'user',
          deviceType: 'ios',
          deviceName: null,
          fileBytes: bytes,
          mimeType: 'application/pdf',
          contentType: ContentType.filePdf,
        );
        if (extra == 0) {
          final item = await sending;
          expect(item.fileSizeBytes, ClipboardLimits.maxFileBytes);
          expect(item.isEncrypted, encrypted);
          expect(row!['file_size_bytes'], ClipboardLimits.maxFileBytes);
          expect(uploads, 1);
          expect(inserts, 1);
          expect(encryptions, encrypted ? 1 : 0);
        } else {
          await expectLater(sending, throwsA(isA<ValidationException>()));
          expect(encryptions, 0, reason: 'Reject before encryption work.');
          expect(uploads, 0, reason: 'Reject before upload.');
          expect(inserts, 0);
        }
      });
    }
  }
}
