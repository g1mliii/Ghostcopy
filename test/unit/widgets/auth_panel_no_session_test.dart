import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/notification_service.dart';
import 'package:ghostcopy/ui/widgets/auth_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records which account-creation call the panel made, then fails it so the
/// panel stops there instead of running its post-login work.
class _FakeAuth implements IAuthService {
  _FakeAuth({required this.user});

  final User? user;
  final calls = <String>[];

  @override
  User? get currentUser => user;

  @override
  String? get currentUserId => user?.id;

  @override
  bool get isAnonymous => user?.isAnonymous ?? true;

  @override
  bool get isAwaitingBrowserSignIn => false;

  @override
  Future<AuthResponse> signUpWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    calls.add('signUpWithEmail');
    throw Exception('stop');
  }

  @override
  Future<UserResponse> upgradeWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    calls.add('upgradeWithEmail');
    throw Exception('stop');
  }

  @override
  Future<bool> signInWithGoogle() async {
    calls.add('signInWithGoogle');
    throw Exception('stop');
  }

  @override
  Future<bool> linkGoogleIdentity() async {
    calls.add('linkGoogleIdentity');
    throw Exception('stop');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeNotifications implements INotificationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSync implements IClipboardSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _guest = User(
  id: 'guest',
  appMetadata: {},
  userMetadata: {},
  aud: 'authenticated',
  createdAt: '2026-01-01T00:00:00Z',
  isAnonymous: true,
);

Future<void> _openCreateAccount(WidgetTester tester, _FakeAuth auth) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: AuthPanel(
            authService: auth,
            notificationService: _FakeNotifications(),
            clipboardSyncService: _FakeSync(),
            onClose: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Create Account').first);
  await tester.pumpAndSettle();
}

Future<void> _submitEmail(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'me@example.com',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    'password1',
  );
  await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
  await tester.pumpAndSettle();
}

/// Startup's anonymous sign-in can fail and leave the panel usable with no
/// session until recovery retries. Upgrading and linking both need a session,
/// so creating an account in that window has to be a plain sign-up.
void main() {
  testWidgets('with no session, email sign-up creates the account', (
    tester,
  ) async {
    final auth = _FakeAuth(user: null);
    await _openCreateAccount(tester, auth);

    await _submitEmail(tester);

    expect(auth.calls, ['signUpWithEmail']);
  });

  testWidgets('a guest still upgrades in place', (tester) async {
    final auth = _FakeAuth(user: _guest);
    await _openCreateAccount(tester, auth);

    await _submitEmail(tester);

    expect(auth.calls, ['upgradeWithEmail']);
  });

  testWidgets('with no session, Google signs in instead of linking', (
    tester,
  ) async {
    final auth = _FakeAuth(user: null);
    await _openCreateAccount(tester, auth);

    await tester.tap(find.byTooltip('Continue with Google'));
    await tester.pumpAndSettle();

    expect(auth.calls, ['signInWithGoogle']);
  });

  testWidgets('a guest still links Google in place', (tester) async {
    final auth = _FakeAuth(user: _guest);
    await _openCreateAccount(tester, auth);

    await tester.tap(find.byTooltip('Continue with Google'));
    await tester.pumpAndSettle();

    expect(auth.calls, ['linkGoogleIdentity']);
  });
}
