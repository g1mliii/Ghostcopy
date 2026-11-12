import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/distribution_consent_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/screens/distribution_onboarding.dart';
import 'package:ghostcopy/ui/theme/app_theme.dart';
import 'package:ghostcopy/ui/theme/appearance.dart';
import 'package:ghostcopy/ui/theme/colors.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const mobile = TargetPlatformVariant({TargetPlatform.android});
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
          home: DistributionOnboarding(prefs: prefs, onAccepted: accepted),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  Future<void> choose(WidgetTester tester, String age) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(age).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('under-16 choice persists and never starts services', (
    tester,
  ) async {
    var calls = 0;
    final prefs = await pump(tester, () => calls++);
    await choose(tester, 'Under 16');
    expect(prefs.getBool(IDistributionConsentService.blockedKey), isTrue);
    expect(DistributionConsentService(prefs).isAccepted, isFalse);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, () => calls++);
    expect(find.text('GhostCopy is for ages 16+'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
  }, variant: mobile);

  testWidgets(
    'teen setup requires terms and guardian acknowledgement before completion',
    (tester) async {
      var calls = 0;
      final prefs = await pump(tester, () => calls++);
      await choose(tester, '16–17');
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile).first);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile).last);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pump();
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(DistributionConsentService(prefs).isAccepted, isFalse);
      await tester.ensureVisible(find.text('Finish setup'));
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(DistributionConsentService(prefs).isAccepted, isTrue);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    },
    variant: mobile,
  );

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

  test('headless startup cannot accept notices', () async {
    await expectLater(
      ensureDistributionConsent(headless: true),
      throwsException,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(DistributionConsentService(prefs).isAccepted, isFalse);
  });
}
