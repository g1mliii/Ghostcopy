import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/media_memory_cache.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(Uint8List(0)));

  final source = img.Image(width: 2400, height: 4);
  for (var x = 0; x < source.width; x++) {
    for (var y = 0; y < source.height; y++) {
      source.setPixelRgb(x, y, x % 256, y * 60, (x ~/ 8) % 256);
    }
  }
  final fixtures = <ContentType, Uint8List>{
    ContentType.imagePng: Uint8List.fromList(img.encodePng(source)),
    ContentType.imageJpeg: Uint8List.fromList(img.encodeJpg(source)),
    ContentType.imageGif: Uint8List.fromList(img.encodeGif(source)),
    ContentType.filePdf: Uint8List.fromList(
      utf8.encode('%PDF-1.7\noriginal file\n'),
    ),
  };

  for (final encrypted in [false, true]) {
    for (final entry in fixtures.entries) {
      test(
        '${entry.key.value} keeps original bytes (encrypted: $encrypted)',
        () async {
          final encryption = _Encryption();
          final storage = _Storage();
          final cache = MediaMemoryCache.instance..clear();
          addTearDown(cache.clear);
          Map<String, Object?>? row;
          Uint8List? uploaded;
          final client = SupabaseClient(
            'https://example.com',
            'anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
              expect(request.method, 'POST');
              row = jsonDecode(request.body) as Map<String, Object?>;
              return http.Response(
                jsonEncode({
                  ...row!,
                  'id': 'clip',
                  'created_at': '2026-09-23T00:00:00Z',
                }),
                200,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }),
          );
          addTearDown(client.dispose);
          final expiry =
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000;
          final token = base64Url
              .encode(utf8.encode(jsonEncode({'sub': 'user', 'exp': expiry})))
              .replaceAll('=', '');
          await client.auth.recoverSession(
            jsonEncode({
              'access_token': 'e30.$token.signature',
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
          when(() => encryption.initialize('user')).thenAnswer((_) async {});
          when(encryption.isEnabled).thenAnswer((_) async => encrypted);
          // Reversible test envelope checks what crosses the encryption boundary.
          when(() => encryption.encryptBytes(any())).thenAnswer((call) async {
            final input = call.positionalArguments.single as Uint8List;
            expect(input, orderedEquals(entry.value));
            return Uint8List.fromList([99, ...input]);
          });
          when(() => encryption.decryptBytes(any())).thenAnswer((call) async {
            final input = call.positionalArguments.single as Uint8List;
            return Uint8List.fromList(input.sublist(1));
          });
          final path = 'quality-test/${entry.key.name}/$encrypted';
          when(
            () => storage.uploadFile(
              userId: any(named: 'userId'),
              clipboardId: any(named: 'clipboardId'),
              bytes: any(named: 'bytes'),
              filename: any(named: 'filename'),
              mimeType: any(named: 'mimeType'),
            ),
          ).thenAnswer((call) async {
            uploaded = call.namedArguments[#bytes] as Uint8List;
            expect(call.namedArguments[#mimeType], entry.key.mimeType);
            return UploadResult(
              storagePath: path,
              fileSizeBytes: uploaded!.length,
            );
          });
          when(
            () => storage.downloadFile(path),
          ).thenAnswer((_) async => uploaded!);
          final repository = ClipboardRepository(
            client: client,
            encryptionService: encryption,
            storageService: storage,
          );
          addTearDown(repository.dispose);
          final item = await repository.insertFile(
            userId: 'user',
            deviceType: 'ios',
            deviceName: null,
            fileBytes: entry.value,
            mimeType: entry.key.mimeType!,
            contentType: entry.key,
            originalFilename: 'original.${entry.key.fileExtension}',
            width: entry.key.isImage ? 2400 : null,
            height: entry.key.isImage ? 4 : null,
          );
          expect(
            uploaded,
            orderedEquals(encrypted ? [99, ...entry.value] : entry.value),
          );
          expect(row?['mime_type'], entry.key.mimeType);
          expect(row?['is_encrypted'], encrypted);
          expect(item.isEncrypted, encrypted);
          expect(
            await repository.downloadFile(item),
            orderedEquals(entry.value),
          );
          // Preview/download consumers share raw cached bytes, never a thumbnail.
          expect(
            await repository.downloadFile(item),
            orderedEquals(entry.value),
          );
          verify(() => storage.downloadFile(path)).called(1);
        },
      );
    }
  }
}
