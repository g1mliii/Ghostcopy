import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/locator.dart';
import 'package:ghostcopy/services/auth_service.dart';
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
  Exception? failure;
  Completer<void>? pending;
  @override
  Future<Map<String, Object?>> poll() async => {
    'status': 'authorized',
    'hasAccount': true,
  };
  @override
  Future<CloudAuthorization> authorize(String accessToken) async {
    await pending?.future;
    final error = failure;
    if (error != null) throw error;
    CloudConsentService.parentManaged.value = true;
    return CloudAuthorization(
      allowed: allowed,
      parentManaged: true,
      fileSync: false,
    );
  }
}

class _Auth extends Mock implements IAuthService {}

class _Draft extends StatefulWidget {
  const _Draft();
  @override
  State<_Draft> createState() => _DraftState();
}

class _DraftState extends State<_Draft> {
  final controller = TextEditingController();
  bool attachment = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(controller: controller),
        TextButton(
          onPressed: () => setState(() => attachment = true),
          child: const Text('Attach file'),
        ),
        if (attachment) const Text('draft.pdf'),
      ],
    ),
  );
}

Map<String, Object?> _session(String id, [String signature = 'signature']) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': id, 'exp': expires})))
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$payload.$signature',
    'refresh_token': 'refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expires,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'is_anonymous': true,
    },
  };
}

/// Leases like the server: 15 minutes from each check, cached per token.
class _LeaseConsent extends CloudConsentService {
  _LeaseConsent(this.clock);
  final DateTime Function() clock;
  final checks = <DateTime>[];
  bool allowed = true;
  bool eligible = false;

  /// Answer with the lease already held, as the server does while the
  /// device clock runs ahead of it.
  bool renew = true;
  CloudAuthorization? _cached;

  @override
  Future<Map<String, Object?>> poll() async => {
    'status': 'authorized',
    'hasAccount': true,
    'independentEligible': eligible,
  };

  @override
  Future<CloudAuthorization> authorize(String accessToken) async {
    checks.add(clock());
    CloudConsentService.parentManaged.value = true;
    final held = _cached?.validUntil;
    return _cached = CloudAuthorization(
      allowed: allowed,
      parentManaged: true,
      fileSync: false,
      validUntil: !renew && held != null
          ? held
          : clock().add(const Duration(minutes: 15)),
    );
  }

  @override
  CloudAuthorization? freshAuthorizationForSession(String accessToken) {
    final cached = _cached;
    return cached != null &&
            cached.allowed &&
            cached.validUntil!.isAfter(
              clock().add(CloudConsentService.leaseMargin),
            )
        ? cached
        : null;
  }
}

void main() {
  setUp(() => CloudConsentService.parentManaged.value = false);

  testWidgets(
    'auth errors and refresh preserve drafts; switching accounts blocks immediately',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await DistributionConsentService(
        prefs,
      ).acceptParentManaged(country: 'CA');
      CloudConsentService.seedParentManaged(prefs);
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient(
            (_) async =>
                http.Response(jsonEncode(_session('child', 'refreshed')), 200),
          ),
        ),
      ))!;
      await client.auth.recoverSession(jsonEncode(_session('child')));
      // A new subscriber receives earlier GoTrue errors as well as events.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(
        const AuthException('stale PKCE callback'),
        StackTrace.current,
      );
      final encryption = _Encryption();
      final revision = ValueNotifier(0);
      when(() => encryption.keyRevision).thenReturn(revision);
      when(() => encryption.initialize(any())).thenAnswer((_) async {});
      when(encryption.isEnabled).thenAnswer((_) async => true);
      final consent = _Consent();
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAccessGuard(
            client: client,
            consent: consent,
            encryption: encryption,
            isDesktop: false,
            builder: () => const _Draft(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'unsent clip');
      await tester.tap(find.text('Attach file'));
      await tester.pump();
      final draft = tester.state(find.byType(_Draft));
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(
        const AuthException('failed callback'),
        StackTrace.current,
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Draft)), same(draft));
      expect(find.text('draft.pdf'), findsOneWidget);
      consent.pending = Completer<void>();
      await client.auth.refreshSession();
      await tester.pump();
      expect(find.text('unsent clip'), findsOneWidget);
      expect(find.text('draft.pdf'), findsOneWidget);
      expect(tester.state(find.byType(_Draft)), same(draft));
      consent.pending!.complete();
      consent.pending = null;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Draft)), same(draft));
      expect(find.text('draft.pdf'), findsOneWidget);
      consent.pending = Completer<void>();
      await client.auth.recoverSession(jsonEncode(_session('other')));
      await tester.pump();
      expect(find.byType(_Draft), findsNothing);
      expect(find.text('unsent clip'), findsNothing);
      consent.allowed = false;
      consent.pending!.complete();
      consent.pending = null;
      await tester.pumpAndSettle();
      expect(find.byType(_Draft), findsNothing);
      expect(find.text('Ask for parent permission again'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'a signed-out bound claim offers recovery without creating another guest',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await DistributionConsentService(
        prefs,
      ).acceptParentManaged(country: 'CA');
      CloudConsentService.seedParentManaged(prefs);
      final requests = <String>[];
      final client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            requests.add(request.url.path);
            return http.Response('{}', 200);
          }),
        ),
      ))!;
      final auth = _Auth();
      locator.registerSingleton<IAuthService>(auth);
      final encryption = _Encryption();
      final revision = ValueNotifier(0);
      when(() => encryption.keyRevision).thenReturn(revision);
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAccessGuard(
            client: client,
            consent: _Consent(),
            encryption: encryption,
            isDesktop: false,
            builder: () => const Text('Private clipboard'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore your account'), findsOneWidget);
      expect(find.text('Delete this account'), findsNothing);
      expect(find.text('Link existing device'), findsOneWidget);
      expect(find.text('Private clipboard'), findsNothing);
      verifyNever(auth.initialize);
      expect(requests, isEmpty);
      await tester.tap(find.text('Link existing device'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Link code'), findsOneWidget);
      expect(find.widgetWithText(TextField, '6-digit PIN'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(client.auth.currentSession, isNull);
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      await locator.unregister<IAuthService>();
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

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
      var pushRevocations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAccessGuard(
            client: client,
            consent: consent,
            encryption: encryption,
            isDesktop: false,
            revokePush: () async {
              pushRevocations++;
            },
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
      consent.failure = Exception('Temporary network outage');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private clipboard'), findsNothing);
      expect(pushRevocations, 0);
      consent.failure = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private clipboard'), findsOneWidget);
      expect(authorized, 2); // Retry triggers device registration again.
      expect(pushRevocations, 0);
      consent.allowed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private clipboard'), findsNothing);
      expect(find.text('Ask for parent permission again'), findsOneWidget);
      expect(redirects, 3);
      expect(pushRevocations, 1);
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      await tester.runAsync(client.dispose);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  group('parent lease cadence', () {
    late DateTime now;
    late _LeaseConsent consent;
    late SupabaseClient client;
    late ValueNotifier<int> revision;
    late StreamController<Map<String, dynamic>> rows;

    Future<void> elapse(WidgetTester tester, Duration duration) async {
      now = now.add(duration);
      await tester.pump(duration);
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    Future<void> open(WidgetTester tester, {bool eligible = false}) async {
      final prefs = await SharedPreferences.getInstance();
      await DistributionConsentService(
        prefs,
      ).acceptParentManaged(country: 'CA');
      CloudConsentService.seedParentManaged(prefs);
      now = DateTime.utc(2026, 11, 17, 12);
      consent = _LeaseConsent(() => now)..eligible = eligible;
      rows = StreamController<Map<String, dynamic>>.broadcast();
      client = (await tester.runAsync(
        () async => SupabaseClient(
          'https://example.test',
          'public',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        ),
      ))!;
      await client.auth.recoverSession(jsonEncode(_session('child')));
      final encryption = _Encryption();
      revision = ValueNotifier(0);
      when(() => encryption.keyRevision).thenReturn(revision);
      when(() => encryption.initialize(any())).thenAnswer((_) async {});
      when(encryption.isEnabled).thenAnswer((_) async => true);
      await tester.pumpWidget(
        MaterialApp(
          home: CloudAccessGuard(
            client: client,
            consent: consent,
            encryption: encryption,
            isDesktop: false,
            now: () => now,
            revokePush: () async {},
            watchAuthorization: (_, _) => rows.stream,
            builder: () => const Text('Private clipboard'),
          ),
        ),
      );
      await settle(tester);
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      revision.dispose();
      await rows.close();
      await tester.runAsync(client.dispose);
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets(
      'one check per lease, two minutes before expiry, rescheduled each time',
      (tester) async {
        await open(tester);
        expect(find.text('Private clipboard'), findsOneWidget);
        expect(consent.checks, hasLength(1));
        // Lease 15 minutes: nothing until 13 minutes have passed.
        await elapse(tester, const Duration(minutes: 12, seconds: 59));
        expect(consent.checks, hasLength(1));
        await elapse(tester, const Duration(seconds: 1));
        expect(consent.checks, hasLength(2));
        // The renewed lease reschedules the timer from the new expiry.
        await elapse(tester, const Duration(minutes: 12, seconds: 59));
        expect(consent.checks, hasLength(2));
        await elapse(tester, const Duration(seconds: 1));
        expect(consent.checks, hasLength(3));
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'a lease the server did not renew is retried at its expiry, not every 30 seconds',
      (tester) async {
        await open(tester);
        expect(consent.checks, hasLength(1));
        // The device clock is ahead: the check two minutes before expiry
        // comes back with the same lease.
        consent.renew = false;
        await elapse(tester, const Duration(minutes: 13));
        expect(consent.checks, hasLength(2));
        await elapse(tester, const Duration(minutes: 1, seconds: 59));
        expect(consent.checks, hasLength(2));
        await elapse(tester, const Duration(seconds: 1));
        expect(consent.checks, hasLength(3));
        // Past the device's view of expiry: back off two minutes, not 30s.
        await elapse(tester, const Duration(minutes: 1, seconds: 59));
        expect(consent.checks, hasLength(3));
        await elapse(tester, const Duration(seconds: 1));
        expect(consent.checks, hasLength(4));
        // Once the server renews, the usual margin applies again.
        consent.renew = true;
        await elapse(tester, CloudAccessGuard.unrenewedLeaseDelay);
        expect(consent.checks, hasLength(5));
        await elapse(tester, const Duration(minutes: 12, seconds: 59));
        expect(consent.checks, hasLength(5));
        await elapse(tester, const Duration(seconds: 1));
        expect(consent.checks, hasLength(6));
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'resume reuses a fresh lease and asks the server once it is near expiry',
      (tester) async {
        await open(tester);
        expect(consent.checks, hasLength(1));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await elapse(tester, const Duration(minutes: 10));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await settle(tester);
        expect(consent.checks, hasLength(1));
        expect(find.text('Private clipboard'), findsOneWidget);
        // Paused past the timer: resuming inside the margin renews.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await elapse(tester, const Duration(minutes: 4));
        expect(consent.checks, hasLength(1));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await settle(tester);
        expect(consent.checks, hasLength(2));
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'try again always asks the server; a blocked account retries each minute',
      (tester) async {
        await open(tester);
        consent.allowed = false;
        rows.add({'status': 'revoked', 'cloud_sync': false});
        await settle(tester);
        expect(consent.checks, hasLength(2));
        expect(find.text('Ask for parent permission again'), findsOneWidget);
        await elapse(tester, CloudAccessGuard.retryWithoutLease);
        expect(consent.checks, hasLength(3));
        await tester.tap(find.text('Try again'));
        await settle(tester);
        expect(consent.checks, hasLength(4));
        consent.allowed = true;
        await tester.tap(find.text('Try again'));
        await settle(tester);
        expect(consent.checks, hasLength(5));
        expect(find.text('Private clipboard'), findsOneWidget);
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'a parent withdrawal shows at once; a lease renewal of the row does not recheck',
      (tester) async {
        await open(tester);
        expect(consent.checks, hasLength(1));
        rows.add({
          'status': 'authorized',
          'cloud_sync': true,
          'file_sync': false,
          'account_kind': 'parent_managed',
        });
        await settle(tester);
        expect(consent.checks, hasLength(1));
        consent.allowed = false;
        rows.add({
          'status': 'revoked',
          'cloud_sync': false,
          'file_sync': false,
          'account_kind': 'parent_managed',
        });
        await settle(tester);
        expect(consent.checks, hasLength(2));
        expect(find.text('Private clipboard'), findsNothing);
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'an eligible account confirms adult setup after the first frame',
      (tester) async {
        await open(tester, eligible: true);
        await settle(tester);
        expect(find.text('Your choice, clearly'), findsOneWidget);
        expect(find.text('Private clipboard'), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('distribution_graduation_pending'), isTrue);
        await close(tester);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );
  });
}
