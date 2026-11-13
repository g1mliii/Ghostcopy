import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/ui/widgets/cloud_access_guard.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Consent extends CloudConsentService {
  bool allowed = true;
  @override
  Future<CloudAuthorization> authorize(String accessToken) async =>
      CloudAuthorization(
        allowed: allowed,
        parentManaged: true,
        fileSync: false,
      );
}

void main() {
  testWidgets(
    'one account gate requires encryption and replaces private UI after revocation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await DistributionConsentService(prefs).accept(
        ageGroup: DistributionAgeGroup.adult,
        diagnosticsAllowed: false,
        country: 'CA',
      );
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
      ))!;
      final expires =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
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
            'role': 'authenticated',
            'created_at': '2026-01-01T00:00:00Z',
            'is_anonymous': true,
          },
        }),
      );
      final encryption = _Encryption();
      final revision = ValueNotifier(0);
      var enabled = false;
      when(() => encryption.keyRevision).thenReturn(revision);
      when(() => encryption.initialize('child')).thenAnswer((_) async {});
      when(encryption.isEnabled).thenAnswer((_) async => enabled);
      final consent = _Consent();
      var redirects = 0;
      var authorized = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAccessGuard(
            client: client,
            consent: consent,
            encryption: encryption,
            isDesktop: false,
            onBlocked: () => redirects++,
            onAuthorized: (_) => authorized++,
            builder: () => const Scaffold(body: Text('Private clipboard')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Protect your clips'), findsOneWidget);
      expect(find.text('Private clipboard'), findsNothing);
      expect(redirects, 1);
      expect(authorized, 0);
      enabled = true;
      revision.value++;
      await tester.pumpAndSettle();
      expect(find.text('Private clipboard'), findsOneWidget);
      expect(authorized, 1);
      consent.allowed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private clipboard'), findsNothing);
      expect(find.text('Ask for parent permission again'), findsOneWidget);
      expect(redirects, 2);
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
