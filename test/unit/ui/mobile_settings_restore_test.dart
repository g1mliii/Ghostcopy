import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/locator.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/app_review_service.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/screens/mobile_settings_screen.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends Mock implements IAuthService {}

class _Devices extends Mock implements IDeviceService {}

class _Encryption extends Mock implements IEncryptionService {}

class _Settings extends Mock implements ISettingsService {}

class _Repository extends Mock implements IClipboardRepository {}

class _Reviews extends Mock implements IAppReviewService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Auth auth;
  late _Devices devices;
  late _Encryption encryption;
  late _Settings settings;
  late _Repository repository;
  late ValueNotifier<int> lockedCount;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.com',
      publishableKey: 'test-key',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
    PackageInfo.setMockInitialValues(
      appName: 'GhostCopy',
      packageName: 'com.ghostcopy.ghostcopy',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  tearDownAll(() async => Supabase.instance.dispose());

  setUp(() {
    auth = _Auth();
    devices = _Devices();
    encryption = _Encryption();
    settings = _Settings();
    repository = _Repository();
    lockedCount = ValueNotifier(2);

    when(() => auth.currentUserId).thenReturn('user');
    when(() => auth.isAnonymous).thenReturn(true);
    when(
      () => auth.authStateChanges,
    ).thenAnswer((_) => const Stream<AuthState>.empty());
    when(
      () => devices.getUserDevices(forceRefresh: true),
    ).thenAnswer((_) async => []);
    when(() => encryption.initialize('user')).thenAnswer((_) async {});
    when(encryption.isEnabled).thenAnswer((_) async => false);
    when(encryption.hasCloudBackup).thenAnswer((_) async => false);
    when(encryption.autoRestoreFromCloud).thenAnswer((_) async => false);
    when(() => encryption.setPassphrase(any())).thenAnswer((_) async => true);
    when(encryption.clearPassphrase).thenAnswer((_) async {});
    when(settings.getAutoShortenUrls).thenAnswer((_) async => false);
    when(settings.getScreenshotProtection).thenAnswer((_) async => false);
    when(settings.getAutoSendTargetDevices).thenAnswer((_) async => {});
    when(() => repository.undecryptableItemCount).thenReturn(lockedCount);
    locator
      ..registerSingleton<ISettingsService>(settings)
      ..registerSingleton<IClipboardRepository>(repository);
  });

  tearDown(() async {
    await locator.reset();
    lockedCount.dispose();
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool restore = false,
    IAppReviewService? reviews,
  }) async {
    // Existing settings tiles report this unrelated ink-decoration warning.
    // Forward every other framework error, including layout and async failures.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().startsWith(
        'ListTile background color or ink splashes may be invisible.',
      )) {
        return;
      }
      onError?.call(details);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.pumpWidget(
      MaterialApp(
        home: MobileSettingsScreen(
          authService: auth,
          deviceService: devices,
          settingsService: settings,
          encryptionService: encryption,
          openPassphraseRestore: restore,
          reviewService: reviews,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> restoreFromBanner(WidgetTester tester) async {
    await pumpSettings(tester, restore: true);
    expect(find.text('Restore Access'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'entered passphrase');
    await tester.tap(find.text('Restore Access'));
    await tester.pumpAndSettle();
  }

  testWidgets('banner rejects a passphrase that unlocks no clips', (
    tester,
  ) async {
    when(repository.getHistory).thenAnswer((_) async => []);

    await restoreFromBanner(tester);

    verify(repository.getHistory).called(1);
    verify(encryption.clearPassphrase).called(1);
    expect(
      find.text('That passphrase did not unlock any of your clips'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('banner accepts a passphrase that unlocks some clips', (
    tester,
  ) async {
    when(repository.getHistory).thenAnswer((_) async {
      lockedCount.value = 1;
      return [];
    });

    await restoreFromBanner(tester);

    verify(repository.getHistory).called(1);
    verifyNever(encryption.clearPassphrase);
    expect(
      find.text('1 clip(s) unlocked. 1 still use a different passphrase.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Settings review action opens the store and reports failure',
    (tester) async {
      final reviews = _Reviews();
      when(() => reviews.canReview).thenReturn(true);
      when(reviews.openStoreReview).thenAnswer((_) async => false);
      await pumpSettings(tester, reviews: reviews);
      await tester.scrollUntilVisible(
        find.text('Rate GhostCopy'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Rate GhostCopy'));
      await tester.pumpAndSettle();
      verify(reviews.openStoreReview).called(1);
      verifyNever(
        () => reviews.maybeRequestReview(canPresent: any(named: 'canPresent')),
      );
      expect(
        find.text('Could not open the store. Please try again later.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'Settings hides reviews when public review access is ineligible',
    (tester) async {
      final reviews = _Reviews();
      when(() => reviews.canReview).thenReturn(false);
      await pumpSettings(tester, reviews: reviews);
      expect(find.text('Rate GhostCopy'), findsNothing);
      verifyNever(reviews.openStoreReview);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
