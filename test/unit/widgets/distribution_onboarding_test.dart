import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/cloud_consent_service.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/screens/distribution_onboarding.dart';
import 'package:ghostcopy/ui/theme/app_theme.dart';
import 'package:ghostcopy/ui/theme/appearance.dart';
import 'package:ghostcopy/ui/theme/colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Cloud extends CloudConsentService {
  bool enabled = true;
  bool approved = false;
  String? claim;
  final actions = <String>[];

  @override
  Future<Map<String, Object?>> call(
    String action, {
    Map<String, Object?> data = const {},
    String? accessToken,
  }) async {
    actions.add(action);
    return switch (action) {
      'configuration' => {'childrenEnabled': enabled},
      'start' => {'claimToken': 'a' * 64, 'status': 'pending'},
      _ => {'status': approved ? 'authorized' : 'pending'},
    };
  }

  @override
  Future<void> saveClaim(String token) async {
    claim = token;
  }

  @override
  Future<String?> readClaim() async => claim;
}

void main() {
  late _Cloud cloud;
  const mobile = TargetPlatformVariant({TargetPlatform.android});
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cloud = _Cloud();
  });
  tearDown(() {
    appAppearance.value = AppThemeMode.system;
  });

  Future<SharedPreferences> pump(
    WidgetTester tester,
    VoidCallback accepted,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      AppearanceBuilder(
        builder: (_) => MaterialApp(
          theme: AppTheme.platformTheme,
          home: DistributionOnboarding(
            prefs: prefs,
            onAccepted: accepted,
            cloud: cloud,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  Future<void> choose(WidgetTester tester, String age) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(age).hitTestable(),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text(age).hitTestable().last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byType(DropdownButtonFormField<String>).last,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Canada').hitTestable(),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Canada').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('under-5 choice persists and never starts services', (
    tester,
  ) async {
    var calls = 0;
    final prefs = await pump(tester, () => calls++);
    await choose(tester, 'Under 5');
    expect(prefs.getBool(IDistributionConsentService.blockedKey), isTrue);
    expect(DistributionConsentService(prefs).isAccepted, isFalse);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, () => calls++);
    expect(find.text('Cloud setup is unavailable'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
  }, variant: mobile);

  testWidgets(
    'a checkbox cannot approve a child; verified server permission is required',
    (tester) async {
      var calls = 0;
      final prefs = await pump(tester, () => calls++);
      await choose(tester, '8');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'parent@example.test');
      await tester.ensureVisible(find.text('Send parent request'));
      await tester.tap(find.text('Send parent request'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(DistributionConsentService(prefs).isAccepted, isFalse);
      await tester.tap(find.text('Check permission'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      cloud.approved = true;
      await tester.tap(find.text('Check permission'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      final consent = DistributionConsentService(prefs);
      expect(consent.ageGroup, DistributionAgeGroup.parentManaged);
      expect(consent.diagnosticsAllowed, isFalse);
      expect(cloud.actions, ['configuration', 'start', 'poll', 'poll']);
    },
    variant: mobile,
  );

  testWidgets(
    'unavailable provider collects no parent email and survives restart without age upselling',
    (tester) async {
      cloud.enabled = false;
      var calls = 0;
      final prefs = await pump(tester, () => calls++);
      await choose(tester, '8');
      expect(find.byType(TextField), findsNothing);
      expect(calls, 0);
      expect(prefs.getString('distribution_declared_age'), '8');
      expect(cloud.actions, ['configuration']);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, () => calls++);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>).first,
            )
            .onChanged,
        isNull,
      );
    },
    variant: mobile,
  );

  testWidgets('adult setup defaults diagnostics off', (tester) async {
    var calls = 0;
    final prefs = await pump(tester, () => calls++);
    await choose(tester, '18+');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    await tester.ensureVisible(find.text('Finish setup'));
    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(DistributionConsentService(prefs).isAccepted, isTrue);
    expect(DistributionConsentService(prefs).country, 'CA');
    expect(cloud.actions, isEmpty);
  }, variant: mobile);

  for (final mode in [AppThemeMode.light, AppThemeMode.dark]) {
    testWidgets('onboarding follows saved ${mode.name} theme', (tester) async {
      appAppearance.value = mode;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pump(tester, () {});
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        GhostColors.background,
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        mode == AppThemeMode.light ? Brightness.light : Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    }, variant: mobile);
  }

  testWidgets(
    'first desktop setup is visible before waiting for acceptance',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const window = MethodChannel('window_manager');
      const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
      const presence = MethodChannel('com.ghostcopy/app_presence');
      const display = <String, Object?>{
        'id': '1',
        'size': {'width': 1440.0, 'height': 900.0},
        'visiblePosition': {'dx': 0.0, 'dy': 0.0},
        'visibleSize': {'width': 1440.0, 'height': 860.0},
        'scaleFactor': 1.0,
      };
      final calls = <String>[];
      messenger
        ..setMockMethodCallHandler(window, (call) async {
          calls.add(call.method);
          if (call.method == 'getBounds') {
            return {'x': 0.0, 'y': 0.0, 'width': 540.0, 'height': 720.0};
          }
          return call.method.startsWith('is') ? false : null;
        })
        ..setMockMethodCallHandler(
          screens,
          (call) async => switch (call.method) {
            'getPrimaryDisplay' => display,
            'getAllDisplays' => {
              'displays': [display],
            },
            'getCursorScreenPoint' => {'dx': 700.0, 'dy': 400.0},
            _ => null,
          },
        )
        ..setMockMethodCallHandler(presence, (call) async => null);
      addTearDown(() {
        messenger
          ..setMockMethodCallHandler(window, null)
          ..setMockMethodCallHandler(screens, null)
          ..setMockMethodCallHandler(presence, null);
      });
      var finished = false;
      final setup = ensureDistributionConsent(
        headless: false,
      ).then((_) => finished = true);
      await tester.pumpAndSettle();
      expect(find.byType(DistributionOnboarding), findsOneWidget);
      expect(
        calls,
        containsAllInOrder([
          'ensureInitialized',
          'waitUntilReadyToShow',
          'show',
          'focus',
        ]),
      );
      expect(calls, isNot(contains('hide')));
      expect(finished, isFalse);
      tester
          .widget<DistributionOnboarding>(find.byType(DistributionOnboarding))
          .onAccepted();
      await tester.pumpAndSettle();
      await setup;
      expect(calls.last, 'hide');
      expect(finished, isTrue);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  test('headless startup cannot accept notices', () async {
    await expectLater(
      ensureDistributionConsent(headless: true),
      throwsException,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(DistributionConsentService(prefs).isAccepted, isFalse);
  });
}
