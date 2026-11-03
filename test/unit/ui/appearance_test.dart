import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/theme/app_theme.dart';
import 'package:ghostcopy/ui/theme/appearance.dart';
import 'package:ghostcopy/ui/theme/colors.dart';
import 'package:ghostcopy/ui/widgets/appearance_setting.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends Mock implements ISettingsService {}

void main() {
  setUp(() => appAppearance.value = AppThemeMode.system);
  tearDown(() => appAppearance.value = AppThemeMode.system);

  test(
    'missing and invalid preferences default to system, overrides persist',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.initialize();
      expect(await settings.getThemeMode(), AppThemeMode.system);
      for (final mode in AppThemeMode.values) {
        await settings.setThemeMode(mode);
        final reopened = SettingsService();
        await reopened.initialize();
        expect(await reopened.getThemeMode(), mode);
        reopened.dispose();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', 'unknown');
      expect(await settings.getThemeMode(), AppThemeMode.system);
      settings.dispose();
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'live system changes and saved overrides on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.initialize();
        addTearDown(settings.dispose);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          AppearanceBuilder(
            builder: (context) => MaterialApp(
              navigatorKey: navigator,
              theme: AppTheme.platformTheme,
              themeAnimationDuration: Duration.zero,
              home: Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      const TextField(),
                      TextButton(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => _SettingsPage(settings: settings),
                          ),
                        ),
                        child: const Text('Settings'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), 'draft survives');
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        Brightness brightness() =>
            Theme.of(tester.element(find.byType(AppearanceSetting))).brightness;
        expect(brightness(), Brightness.light);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pumpAndSettle();
        expect(brightness(), Brightness.dark);
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
          GhostColors.background,
        );
        await tester.tap(find.text('Light'));
        await tester.pumpAndSettle();
        expect(brightness(), Brightness.light);
        expect(await settings.getThemeMode(), AppThemeMode.light);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        expect(brightness(), Brightness.dark);
        expect(await settings.getThemeMode(), AppThemeMode.dark);
        await tester.tap(find.text('System'));
        await tester.pumpAndSettle();
        expect(brightness(), Brightness.light);
        expect(await settings.getThemeMode(), AppThemeMode.system);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('draft survives'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets('failed save keeps the current selection and permits retry', (
    tester,
  ) async {
    final settings = _Settings();
    when(
      () => settings.setThemeMode(AppThemeMode.dark),
    ).thenThrow(Exception('disk'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppearanceSetting(settings: settings)),
      ),
    );
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appAppearance.value, AppThemeMode.system);
    expect(find.text('Could not save appearance. Try again.'), findsOneWidget);
    when(
      () => settings.setThemeMode(AppThemeMode.dark),
    ).thenAnswer((_) async {});
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(appAppearance.value, AppThemeMode.dark);
  });
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.settings});
  final ISettingsService settings;
  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    return Scaffold(
      backgroundColor: GhostColors.background,
      body: AppearanceSetting(settings: settings),
    );
  }
}
