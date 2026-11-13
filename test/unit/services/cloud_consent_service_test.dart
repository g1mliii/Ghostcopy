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
    CloudConsentService.currentAccessToken = null;
    final prefs = await SharedPreferences.getInstance();
    await DistributionConsentService(prefs).accept(
      ageGroup: DistributionAgeGroup.adult,
      diagnosticsAllowed: false,
      country: 'CA',
    );
    await prefs.setBool('parent_managed_diagnostics_disabled', true);
  });
  tearDown(() {
    CloudConsentService.currentAccessToken = null;
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
    'diagnostics stop before a child-receipt storage failure can interrupt account reconciliation',
    () async {
      final prefs = await loadConsentPreferences();
      await prefs.remove('parent_managed_diagnostics_disabled');
      final steps = <String>[];
      final storage = _Storage();
      when(
        () => storage.write(key: CloudConsentService.claimKey, value: 'proof'),
      ).thenAnswer((_) async {
        steps.add('write');
        throw Exception('Storage unavailable');
      });
      final service = CloudConsentService(
        storage: storage,
        stopDiagnostics: () async {
          steps.add('stop');
        },
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
      expect(steps, ['stop', 'write']);
      expect(prefs.getBool('parent_managed_diagnostics_disabled'), isTrue);
      expect(CloudConsentService.authorization.value, isNull);
    },
  );
}
