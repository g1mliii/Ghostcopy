import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
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
  for (final kind in [
    'file',
    'image',
    'text',
    'rich text',
    'pending authorization',
  ]) {
    test(
      'parent-managed $kind cannot leave the device without a loaded key',
      () async {
        SharedPreferences.setMockInitialValues({'media_cache_owner': 'child'});
        CloudConsentService.authorization.value = const CloudAuthorization(
          allowed: true,
          parentManaged: true,
          fileSync: true,
        );
        addTearDown(() => CloudConsentService.authorization.value = null);
        addTearDown(() => CloudConsentService.currentAccessToken = null);
        final requests = <http.Request>[];
        final client = SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        final expires =
            DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000;
        final payload = base64Url
            .encode(utf8.encode(jsonEncode({'sub': 'child', 'exp': expires})))
            .replaceAll('=', '');
        await client.auth.recoverSession(
          jsonEncode({
            'access_token': 'e30.$payload.signature',
            'refresh_token': 'refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'expires_at': expires,
            'user': {
              'id': 'child',
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
            },
          }),
        );
        if (kind == 'pending authorization') {
          // A link installed a new session while the previous adult snapshot is
          // still visible. Do not let headless sends reuse that classification.
          CloudConsentService.authorization.value = const CloudAuthorization(
            allowed: true,
            parentManaged: false,
            fileSync: true,
            independentAdult: true,
          );
          CloudConsentService.currentAccessToken = () =>
              client.auth.currentSession?.accessToken;
        }
        final encryption = _Encryption();
        final storage = _Storage();
        when(() => encryption.initialize('child')).thenAnswer((_) async {});
        when(encryption.isEnabled).thenAnswer((_) async => false);
        final repository = ClipboardRepository(
          client: client,
          encryptionService: encryption,
          storageService: storage,
        );
        addTearDown(repository.dispose);
        final Future<ClipboardItem> sending;
        switch (kind) {
          case 'file' || 'pending authorization':
            sending = repository.insertFile(
              userId: 'child',
              deviceType: 'windows',
              deviceName: null,
              fileBytes: Uint8List.fromList([1, 2, 3]),
              mimeType: 'application/pdf',
              contentType: ContentType.filePdf,
            );
          case 'image':
            sending = repository.insertImage(
              userId: 'child',
              deviceType: 'macos',
              deviceName: null,
              imageBytes: Uint8List.fromList([1, 2, 3]),
              mimeType: 'image/png',
              contentType: ContentType.imagePng,
            );
          case 'text':
            sending = repository.insert(
              ClipboardItem(
                id: '',
                userId: 'child',
                content: 'private text',
                deviceType: 'ios',
                createdAt: DateTime.utc(2026),
              ),
            );
          default:
            sending = repository.insertRichText(
              userId: 'child',
              deviceType: 'android',
              deviceName: null,
              content: '<p>private</p>',
              format: RichTextFormat.html,
            );
        }
        await expectLater(sending, throwsA(isA<SecurityException>()));
        expect(
          requests,
          isEmpty,
          reason: 'No plaintext may reach the database.',
        );
        verifyZeroInteractions(storage);
      },
    );
  }
}
