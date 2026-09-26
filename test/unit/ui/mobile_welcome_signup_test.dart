import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/locator.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/ui/screens/mobile_welcome_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// No session before or after sign-up, as when the address still needs
/// confirming. [confirm] then plays the emailed link being opened.
class _FakeAuth implements IAuthService {
  final _events = StreamController<AuthState>.broadcast();
  User? _user;
  int upgrades = 0;

  void confirm() {
    _user = const User(
      id: 'new',
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    );
    _events.add(const AuthState(AuthChangeEvent.signedIn, null));
  }

  @override
  User? get currentUser => _user;

  @override
  String? get currentUserId => _user?.id;

  @override
  bool get isAnonymous => _user?.isAnonymous ?? true;

  @override
  Stream<AuthState> get authStateChanges => _events.stream;

  @override
  Future<UserResponse> upgradeWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    upgrades++;
    return UserResponse.fromJson({
      'id': 'new',
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDevices implements IDeviceService {
  int registrations = 0;

  @override
  Future<bool> registerCurrentDevice({String? fcmToken}) async {
    registrations++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A phone has no guest at first launch, so Create Account there is a plain
/// sign-up, and it has no session until the address is confirmed. Going on
/// into the app would have left the user signed in as nobody.
void main() {
  late _FakeAuth auth;
  late _FakeDevices devices;
  late int completions;

  setUp(() {
    auth = _FakeAuth();
    devices = _FakeDevices();
    completions = 0;
    locator
      ..registerSingleton<IAuthService>(auth)
      ..registerSingleton<IDeviceService>(devices);
  });

  tearDown(locator.reset);

  Future<void> signUp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MobileWelcomeScreen(onAuthComplete: () => completions++),
      ),
    );
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Up').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Email'),
      'new@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'password1',
    );
    await tester.tap(find.text('Sign Up').last);
    await tester.pumpAndSettle();
  }

  testWidgets('waits on the welcome screen for the confirmation', (
    tester,
  ) async {
    await signUp(tester);

    expect(auth.upgrades, 1);
    expect(completions, 0);
    expect(find.textContaining('Check new@example.com'), findsOneWidget);
  });

  testWidgets('moves on when the emailed link signs this phone in', (
    tester,
  ) async {
    await signUp(tester);

    auth.confirm();
    await tester.pumpAndSettle();

    expect(completions, 1);
    expect(devices.registrations, 1);
  });
}
