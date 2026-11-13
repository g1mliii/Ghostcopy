import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/storage_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Storage extends Mock implements IStorageService {}

class _SecureStorage extends Mock implements FlutterSecureStorage {}

Map<String, Object?> _session(String id) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': id, 'exp': expires})))
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$payload.signature',
    'refresh_token': 'refresh-$id',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expires,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'is_anonymous': true,
    },
  };
}

class _Fixture {
  DateTime now = DateTime.utc(2026, 11, 13);
  late DateTime serverLease;
  bool allowed = true;
  bool unavailable = false;
  bool missingExpiry = false;
  int authorizations = 0;
  final events = <String>[];
  final renewStarted = Completer<void>();
  Completer<void>? holdRenewal;
  late SupabaseClient client;
  late CloudConsentService consent;
  late ClipboardRepository repository;

  Future<void> open({bool parentManaged = true}) async {
    serverLease = now.add(const Duration(minutes: 15));
    SharedPreferences.setMockInitialValues({
      'media_cache_owner': 'child',
      'parent_managed_diagnostics_disabled': true,
    });
    final local = DistributionConsentService(
      await SharedPreferences.getInstance(),
    );
    if (parentManaged) {
      await local.acceptParentManaged(country: 'CA');
    } else {
      await local.accept(
        ageGroup: DistributionAgeGroup.adult,
        diagnosticsAllowed: false,
        country: 'CA',
      );
    }
    client = SupabaseClient(
      'https://example.test',
      'public',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        events.add('insert');
        if (!allowed || (parentManaged && !serverLease.isAfter(now))) {
          return http.Response(
            '{"message":"expired authorization","code":"42501"}',
            403,
            request: request,
          );
        }
        final row = jsonDecode(request.body) as Map<String, Object?>;
        expect(row['is_encrypted'], isTrue);
        return http.Response(
          jsonEncode({
            ...row,
            'id': 'clip',
            'created_at': now.toIso8601String(),
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    await client.auth.recoverSession(jsonEncode(_session('child')));
    CloudConsentService.currentAccessToken = () =>
        client.auth.currentSession?.accessToken;
    final secure = _SecureStorage();
    when(
      () => secure.read(key: CloudConsentService.claimKey),
    ).thenAnswer((_) async => 'claim');
    consent = CloudConsentService(
      now: () => now,
      storage: secure,
      client: MockClient((request) async {
        authorizations++;
        events.add('authorize');
        expect(
          (jsonDecode(request.body) as Map<String, Object?>)['action'],
          'authorize',
        );
        if (authorizations > 1) {
          if (!renewStarted.isCompleted) renewStarted.complete();
          await holdRenewal?.future;
        }
        if (unavailable) return http.Response('{"error":"offline"}', 503);
        if (allowed) serverLease = now.add(const Duration(minutes: 15));
        return http.Response(
          jsonEncode({
            'allowed': allowed,
            'accountKind': parentManaged ? 'parent_managed' : 'adult',
            'fileSync': true,
            'validUntil': parentManaged && !missingExpiry
                ? serverLease.toIso8601String()
                : null,
          }),
          200,
        );
      }),
    );
    await consent.authorize(client.auth.currentSession!.accessToken);
    final encryption = _Encryption();
    when(() => encryption.initialize('child')).thenAnswer((_) async {});
    when(encryption.isEnabled).thenAnswer((_) async => true);
    when(() => encryption.encrypt(any())).thenAnswer((_) async => 'ciphertext');
    when(
      () => encryption.encryptBytes(any()),
    ).thenAnswer((_) async => Uint8List.fromList([9, 8, 7]));
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
      expect(
        serverLease.isAfter(now),
        isTrue,
        reason: 'Renewal must precede the upload.',
      );
      events.add('upload');
      expect(call.namedArguments[#bytes], orderedEquals([9, 8, 7]));
      return UploadResult(storagePath: 'child/file.pdf', fileSizeBytes: 3);
    });
    repository = ClipboardRepository(
      client: client,
      encryptionService: encryption,
      storageService: storage,
      cloudConsent: consent,
    );
    events.clear();
  }

  Future<ClipboardItem> sendText() => repository.insert(
    ClipboardItem(
      id: '',
      userId: 'child',
      content: 'private text',
      deviceType: 'windows',
      createdAt: now,
    ),
  );
  Future<ClipboardItem> sendFile() => repository.insertFile(
    userId: 'child',
    deviceType: 'macos',
    deviceName: null,
    fileBytes: Uint8List.fromList([1, 2, 3]),
    mimeType: 'application/pdf',
    contentType: ContentType.filePdf,
  );
  Future<void> close() async {
    repository.dispose();
    await client.dispose();
    CloudConsentService.currentAccessToken = null;
    CloudConsentService.authorization.value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(Uint8List(0)));
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  test(
    'a tray text send renews an expired lease without a focus event or timer',
    () async {
      await fixture.open();
      fixture.now = fixture.now.add(const Duration(minutes: 16));
      expect(
        fixture.authorizations,
        1,
        reason: 'Idle tray mode does not poll.',
      );
      await fixture.sendText();
      expect(fixture.events, ['authorize', 'insert']);
      await fixture.sendText();
      expect(fixture.authorizations, 2, reason: 'A fresh lease is reused.');
    },
  );

  test(
    'a headless/Finder file send renews before uploading encrypted bytes',
    () async {
      await fixture.open();
      fixture.now = fixture.now.add(const Duration(minutes: 16));
      await fixture.sendFile();
      expect(fixture.events, ['authorize', 'upload', 'insert']);
    },
  );

  test('a nearly expired lease renews before the next send', () async {
    await fixture.open();
    fixture.now = fixture.now.add(const Duration(minutes: 14, seconds: 30));
    await fixture.sendText();
    expect(fixture.events, ['authorize', 'insert']);
  });

  test(
    'withdrawn permission prevents both upload and clipboard insertion',
    () async {
      await fixture.open();
      fixture
        ..now = fixture.now.add(const Duration(minutes: 16))
        ..allowed = false;
      await expectLater(
        fixture.sendFile(),
        throwsA(isA<RepositoryException>()),
      );
      expect(fixture.events, ['authorize']);
    },
  );

  test(
    'failed renewal sends no payload and can be retried in the tray',
    () async {
      await fixture.open();
      fixture
        ..now = fixture.now.add(const Duration(minutes: 16))
        ..unavailable = true;
      await expectLater(
        fixture.sendText(),
        throwsA(isA<RepositoryException>()),
      );
      expect(fixture.events, ['authorize']);
      fixture.unavailable = false;
      await fixture.sendText();
      expect(fixture.events, ['authorize', 'authorize', 'insert']);
    },
  );

  test(
    'account switching during renewal cannot send the old account payload',
    () async {
      await fixture.open();
      fixture
        ..now = fixture.now.add(const Duration(minutes: 16))
        ..holdRenewal = Completer<void>();
      final sending = fixture.sendFile();
      final checked = expectLater(sending, throwsA(isA<RepositoryException>()));
      await fixture.renewStarted.future;
      await fixture.client.auth.recoverSession(jsonEncode(_session('other')));
      fixture.holdRenewal!.complete();
      await checked;
      expect(fixture.events, ['authorize']);
    },
  );

  test('concurrent tray sends share a single permission renewal', () async {
    await fixture.open();
    fixture
      ..now = fixture.now.add(const Duration(minutes: 16))
      ..holdRenewal = Completer<void>();
    final first = fixture.sendText();
    await fixture.renewStarted.future;
    final second = fixture.sendText();
    await pumpEventQueue();
    fixture.holdRenewal!.complete();
    await Future.wait([first, second]);
    expect(fixture.authorizations, 2);
    expect(fixture.events, ['authorize', 'insert', 'insert']);
  });

  test('an invalid parent lease cannot permit an upload', () async {
    await fixture.open();
    fixture
      ..now = fixture.now.add(const Duration(minutes: 16))
      ..missingExpiry = true;
    await expectLater(fixture.sendFile(), throwsA(isA<RepositoryException>()));
    expect(fixture.events, ['authorize']);
  });

  test(
    'independent accounts do not acquire a per-send permission request',
    () async {
      await fixture.open(parentManaged: false);
      fixture.now = fixture.now.add(const Duration(minutes: 16));
      await fixture.sendText();
      expect(fixture.authorizations, 1);
      expect(fixture.events, ['insert']);
    },
  );
}
