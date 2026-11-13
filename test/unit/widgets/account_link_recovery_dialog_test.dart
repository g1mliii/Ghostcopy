import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/ui/widgets/account_link_recovery_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends Mock implements IAuthService {}

void main() {
  testWidgets(
    'recovery retries a wrong PIN and signs into the linked account without signup',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'distribution_cloud_paused': true,
      });
      final auth = _Auth();
      when(
        () => auth.signInWithRefreshToken('linked-refresh'),
      ).thenAnswer((_) async {});
      final requests = <http.Request>[];
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request);
            expect(request.url.path, '/functions/v1/exchange-link-token');
            final body = jsonDecode(request.body) as Map<String, Object?>;
            expect(body['token'], 'a' * 64);
            return body['pin'] == '123456'
                ? http.Response(
                    '{"refresh_token":"linked-refresh"}',
                    200,
                    headers: {'content-type': 'application/json'},
                  )
                : http.Response(
                    '{"error":"invalid_pin"}',
                    403,
                    headers: {'content-type': 'application/json'},
                  );
          }),
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) =>
                      AccountLinkRecoveryDialog(client: client, auth: auth),
                ),
                child: const Text('Open recovery'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open recovery'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Link code'),
        'not a token',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '6-digit PIN'),
        '000000',
      );
      await tester.runAsync(
        tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Restore account'),
                )
                .onPressed!
            as Future<void> Function(),
      );
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, 'Link code'),
        jsonEncode({'link_token': 'a' * 64, 'version': 2}),
      );
      await tester.runAsync(
        tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Restore account'),
                )
                .onPressed!
            as Future<void> Function(),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not link.'), findsOneWidget);
      verifyNever(() => auth.signInWithRefreshToken(any()));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('distribution_cloud_paused'), isTrue);
      await tester.enterText(
        find.widgetWithText(TextField, '6-digit PIN'),
        '123456',
      );
      await tester.runAsync(
        tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Restore account'),
                )
                .onPressed!
            as Future<void> Function(),
      );
      await tester.pumpAndSettle();
      verify(() => auth.signInWithRefreshToken('linked-refresh')).called(1);
      expect(prefs.getBool('distribution_cloud_paused'), isFalse);
      expect(find.byType(AccountLinkRecoveryDialog), findsNothing);
      expect(requests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
