import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CloudConsentService.authorization.value = null;
    CloudConsentService.parentManaged.value = false;
    CloudConsentService.currentAccessToken = null;
    final prefs = await SharedPreferences.getInstance();
    await DistributionConsentService(prefs).accept(
      ageGroup: DistributionAgeGroup.adult,
      diagnosticsAllowed: false,
      country: 'CA',
    );
  });
  tearDown(() {
    CloudConsentService.currentAccessToken = null;
  });

  test(
    'cancellation discards the local claim only after server confirmation',
    () async {
      for (final status in [200, 409, 503]) {
        final storage = _Storage();
        when(
          () => storage.read(key: CloudConsentService.claimKey),
        ).thenAnswer((_) async => 'claim');
        when(
          () => storage.delete(key: CloudConsentService.claimKey),
        ).thenAnswer((_) async {});
        final service = CloudConsentService(
          storage: storage,
          client: MockClient((request) async {
            expect(jsonDecode(request.body), {
              'action': 'cancel',
              'claimToken': 'claim',
            });
            return http.Response('{"cancelled":true}', status);
          }),
        );
        if (status == 200) {
          await service.cancelPending();
          verify(
            () => storage.delete(key: CloudConsentService.claimKey),
          ).called(1);
        } else {
          await expectLater(
            service.cancelPending(),
            throwsA(isA<CloudConsentException>()),
          );
          verifyNever(() => storage.delete(key: CloudConsentService.claimKey));
        }
      }
    },
  );

  test(
    'only explicit adult classification permits adult diagnostics',
    () async {
      for (final kind in ['adult', 'unclassified', 'parent_managed', null]) {
        final service = CloudConsentService(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'allowed': true,
                'accountKind': kind,
                'fileSync': false,
              }),
              200,
            ),
          ),
        );
        final result = await service.authorize('session');
        expect(result.independentAdult, kind == 'adult');
      }
    },
  );

  test(
    'adult acknowledgement submits graduation and clears the old device claim after authorization',
    () async {
      for (final optedIn in [false, true]) {
        final prefs = await SharedPreferences.getInstance();
        await DistributionConsentService(prefs).accept(
          ageGroup: DistributionAgeGroup.adult,
          diagnosticsAllowed: optedIn,
          country: 'CA',
        );
        await prefs.setBool('distribution_graduation_pending', true);
        final storage = _Storage();
        when(
          () => storage.delete(key: CloudConsentService.claimKey),
        ).thenAnswer((_) async {});
        final service = CloudConsentService(
          storage: storage,
          client: MockClient((request) async {
            final data = jsonDecode(request.body) as Map<String, Object?>;
            expect(data['graduate'], isTrue);
            expect(data['termsAccepted'], isTrue);
            expect(data['privacyAcknowledged'], isTrue);
            return http.Response(
              '{"allowed":true,"accountKind":"adult","fileSync":true}',
              200,
            );
          }),
        );
        expect((await service.authorize('session')).independentAdult, isTrue);
        expect(prefs.getBool('distribution_graduation_pending'), isNull);
        expect(prefs.getString('distribution_declared_age'), '18+');
        expect(DistributionConsentService(prefs).diagnosticsAllowed, optedIn);
        expect(CloudConsentService.parentManaged.value, isFalse);
        verify(
          () => storage.delete(key: CloudConsentService.claimKey),
        ).called(1);
      }
    },
  );

  test('unconfirmed or stale graduation stays pending', () async {
    for (final scenario in ['denied', 'parent', 'unclassified', 'stale']) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('distribution_graduation_pending', true);
      final service = CloudConsentService(
        client: MockClient((request) async {
          if (scenario == 'stale') {
            CloudConsentService.currentAccessToken = () => 'new-session';
          }
          return http.Response(
            jsonEncode({
              'allowed': scenario != 'denied',
              'accountKind': scenario == 'parent'
                  ? 'parent_managed'
                  : scenario == 'unclassified'
                  ? 'unclassified'
                  : 'adult',
            }),
            200,
          );
        }),
      );
      CloudConsentService.currentAccessToken = () => 'session';
      await service.authorize('session');
      expect(prefs.getBool('distribution_graduation_pending'), isTrue);
    }
  });

  test('only approved unbound parent setup may create a first guest', () async {
    final prefs = await SharedPreferences.getInstance();
    await DistributionConsentService(prefs).acceptParentManaged(country: 'CA');
    CloudConsentService.seedParentManaged(prefs);
    final storage = _Storage();
    when(
      () => storage.read(key: CloudConsentService.claimKey),
    ).thenAnswer((_) async => 'claim');
    Object? hasAccount = false;
    var status = 'authorized';
    final service = CloudConsentService(
      storage: storage,
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'status': status, 'hasAccount': hasAccount}),
          200,
        ),
      ),
    );
    await service.beforeGuestCreation();
    hasAccount = true;
    await expectLater(service.beforeGuestCreation(), throwsException);
    hasAccount = null; // Older or incomplete responses must fail closed.
    await expectLater(service.beforeGuestCreation(), throwsException);
    hasAccount = false;
    status = 'pending';
    await expectLater(service.beforeGuestCreation(), throwsException);
    status = 'authorized';
    await prefs.setBool('distribution_cloud_paused', true);
    await expectLater(service.beforeGuestCreation(), throwsException);
  });

  test(
    'central account check sends the current notice and uses server classification',
    () async {
      final service = CloudConsentService(
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer session');
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['action'], 'authorize');
          expect(body['country'], 'CA');
          expect(body['noticeVersion'], IDistributionConsentService.version);
          return http.Response(
            jsonEncode({
              'allowed': false,
              'accountKind': 'parent_managed',
              'fileSync': false,
            }),
            200,
          );
        }),
      );
      final result = await service.authorize('session');
      expect(result.allowed, isFalse);
      expect(result.parentManaged, isTrue);
      expect(CloudConsentService.authorization.value?.parentManaged, isTrue);
    },
  );

  test(
    'late authorization of a previous account cannot replace current child state',
    () async {
      final adultResponse = Completer<http.Response>();
      final started = Completer<void>();
      var active = 'old';
      CloudConsentService.currentAccessToken = () => active;
      final service = CloudConsentService(
        client: MockClient((request) async {
          if (request.headers['Authorization'] == 'Bearer old') {
            started.complete();
            return adultResponse.future;
          }
          return http.Response(
            jsonEncode({
              'allowed': true,
              'accountKind': 'parent_managed',
              'fileSync': false,
            }),
            200,
          );
        }),
      );
      final old = service.authorize('old');
      await started.future;
      active = 'new';
      await service.authorize('new');
      adultResponse.complete(
        http.Response(
          jsonEncode({
            'allowed': true,
            'accountKind': 'adult',
            'fileSync': true,
          }),
          200,
        ),
      );
      await old;
      expect(CloudConsentService.authorization.value?.parentManaged, isTrue);
      expect(CloudConsentService.authorization.value?.fileSync, isFalse);
      expect(CloudConsentService.authorizationForSession('old'), isNull);
      expect(
        CloudConsentService.authorizationForSession('new')?.parentManaged,
        isTrue,
      );
    },
  );

  test(
    'transport failure exposes a sanitized error and never asserts authorization',
    () async {
      final service = CloudConsentService(
        client: MockClient(
          (_) async =>
              http.Response('{"error":"private provider details"}', 503),
        ),
      );
      await expectLater(
        service.authorize('session'),
        throwsA(isA<CloudConsentException>()),
      );
      expect(CloudConsentService.authorization.value, isNull);
    },
  );

  test(
    'linking an authorized child replaces an adult local receipt before the next launch',
    () async {
      final storage = _Storage();
      when(
        () => storage.write(
          key: CloudConsentService.claimKey,
          value: 'signed-device-proof',
        ),
      ).thenAnswer((_) async {});
      final service = CloudConsentService(
        storage: storage,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'allowed': true,
              'accountKind': 'parent_managed',
              'fileSync': false,
              'deviceClaim': 'signed-device-proof',
              'country': 'CA',
              'ageAtSetup': 8,
            }),
            200,
          ),
        ),
      );
      await service.authorize('child-session');
      final prefs = await loadConsentPreferences();
      final receipt = DistributionConsentService(prefs);
      expect(receipt.ageGroup, DistributionAgeGroup.parentManaged);
      expect(receipt.diagnosticsAllowed, isFalse);
      expect(prefs.getString('distribution_declared_age'), '8');
      verify(
        () => storage.write(
          key: CloudConsentService.claimKey,
          value: 'signed-device-proof',
        ),
      ).called(1);
    },
  );

  test(
    'a child-receipt storage failure leaves the account unclassified',
    () async {
      final storage = _Storage();
      when(
        () => storage.write(key: CloudConsentService.claimKey, value: 'proof'),
      ).thenAnswer((_) async => throw Exception('Storage unavailable'));
      final service = CloudConsentService(
        storage: storage,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'allowed': true,
              'accountKind': 'parent_managed',
              'fileSync': false,
              'deviceClaim': 'proof',
              'country': 'CA',
              'ageAtSetup': 8,
            }),
            200,
          ),
        ),
      );
      await expectLater(service.authorize('child'), throwsException);
      expect(CloudConsentService.authorization.value, isNull);
      expect(CloudConsentService.parentManaged.value, isFalse);
    },
  );

  group('parentManaged', () {
    test('is seeded from the local receipt', () async {
      final prefs = await loadConsentPreferences();
      CloudConsentService.seedParentManaged(prefs);
      expect(CloudConsentService.parentManaged.value, isFalse);
      await DistributionConsentService(
        prefs,
      ).acceptParentManaged(country: 'CA');
      CloudConsentService.seedParentManaged(prefs);
      expect(CloudConsentService.parentManaged.value, isTrue);
      await prefs.remove(IDistributionConsentService.receiptKey);
      CloudConsentService.seedParentManaged(prefs);
      expect(CloudConsentService.parentManaged.value, isFalse);
    });

    test('follows each server classification of the current session', () async {
      var kind = 'parent_managed';
      final service = CloudConsentService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'allowed': true,
              'accountKind': kind,
              'fileSync': false,
              'validUntil': '2099-01-01T00:00:00Z',
            }),
            200,
          ),
        ),
      );
      final notified = <bool>[];
      void record() => notified.add(CloudConsentService.parentManaged.value);
      CloudConsentService.parentManaged.addListener(record);
      addTearDown(
        () => CloudConsentService.parentManaged.removeListener(record),
      );
      // The local receipt says adult; the server decides.
      await service.authorize('first');
      expect(CloudConsentService.parentManaged.value, isTrue);
      kind = 'adult';
      await service.authorize('second');
      expect(CloudConsentService.parentManaged.value, isFalse);
      expect(notified, [true, false]);
    });

    test('a stale session response cannot change it', () async {
      CloudConsentService.currentAccessToken = () => 'current';
      final service = CloudConsentService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'allowed': true,
              'accountKind': 'parent_managed',
              'fileSync': false,
            }),
            200,
          ),
        ),
      );
      await service.authorize('previous');
      expect(CloudConsentService.parentManaged.value, isFalse);
    });
  });

  test(
    'a cached classification stands in for a check only while its lease is fresh',
    () async {
      var now = DateTime.utc(2026, 11, 17, 12);
      final lease = now.add(const Duration(minutes: 15));
      var kind = 'parent_managed';
      var allowed = true;
      var calls = 0;
      final service = CloudConsentService(
        now: () => now,
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'allowed': allowed,
              'accountKind': kind,
              'fileSync': false,
              'validUntil': lease.toIso8601String(),
            }),
            200,
          );
        }),
      );
      expect(service.freshAuthorizationForSession('session'), isNull);
      await service.authorize('session');
      expect(service.freshAuthorizationForSession('session'), isNotNull);
      expect(service.freshAuthorizationForSession('refreshed'), isNull);
      now = lease.subtract(
        CloudConsentService.leaseMargin + const Duration(seconds: 1),
      );
      expect(service.freshAuthorizationForSession('session'), isNotNull);
      now = lease.subtract(CloudConsentService.leaseMargin);
      expect(service.freshAuthorizationForSession('session'), isNull);
      // An adult has no lease to expire.
      kind = 'adult';
      await service.authorize('session');
      now = lease.add(const Duration(days: 1));
      expect(service.freshAuthorizationForSession('session'), isNotNull);
      // A refusal is never reused: returning to the app asks again.
      allowed = false;
      await service.authorize('session');
      expect(service.freshAuthorizationForSession('session'), isNull);
      expect(calls, 3);
    },
  );
}
