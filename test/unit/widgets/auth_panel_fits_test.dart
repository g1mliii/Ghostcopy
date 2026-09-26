import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/notification_service.dart';
import 'package:ghostcopy/ui/widgets/auth_panel.dart';

/// What the form actually gets, which is not the whole window.
///
/// `_buildAuthPanel` in spotlight_screen.dart gives the panel a fixed width of
/// 400 - narrower than the 500px Spotlight - and stacks a header ("Upgrade
/// Account", with icon and close button) and a divider above it, handing the
/// rest to AuthPanel through an Expanded. So the form's real budget is the
/// window height minus that chrome.
///
/// The chrome is over-estimated on purpose rather than reproduced here. A copy
/// of the header would drift from the real one silently; a number that is
/// certainly larger than it cannot, and only ever makes this test stricter
/// than the app.
const double _panelWidth = 400;
const double _windowHeight = 400;
const double _chromeAllowance = 60;
const Size _spotlight = Size(_panelWidth, _windowHeight - _chromeAllowance);

/// Headroom for the platform the panel is NOT being tested on.
///
/// The bundled fonts in pubspec.yaml are commented out, so the app renders in
/// whatever the system supplies - SF on macOS, Segoe UI on Windows - and Segoe
/// is the taller of the two at the same point size. A widget test renders in
/// neither: it uses the test font, whose metrics match no real platform. So
/// "fits exactly in the test" would prove nothing about Windows, which is
/// where the scrolling was reported. Measuring at a larger text scale instead
/// gives the layout room to be wrong about font metrics by this much and still
/// fit, and it is the same slack that covers a user who has nudged their
/// system text size up.
const double _headroom = 1.15;

class _FakeAuth implements IAuthService {
  @override
  bool get isAnonymous => true;

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

Future<double> _contentHeight(
  WidgetTester tester, {
  required bool login,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(
        size: _spotlight,
        textScaler: TextScaler.linear(_headroom),
      ),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _spotlight.width,
              height: _spotlight.height,
              child: AuthPanel(
                authService: _FakeAuth(),
                notificationService: _FakeNotifications(),
                clipboardSyncService: _FakeSync(),
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (!login) {
    await tester.tap(find.text('Create Account').first);
    await tester.pumpAndSettle();
  }

  final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
  final position =
      scrollable.controller?.position ??
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  // How far the form could be scrolled. Zero means every control is on screen.
  return position.maxScrollExtent;
}

void main() {
  // Both modes, because Create Account swaps the forgot-password link for the
  // guest-clips explanation and the two are not the same height - the mode
  // that fits is not evidence about the one that does not.
  testWidgets('Sign In fits the Spotlight without scrolling', (tester) async {
    final overflow = await _contentHeight(tester, login: true);
    expect(
      overflow,
      0.0,
      reason:
          'the sign-in form needs $overflow more logical pixels than the '
          'Spotlight gives it, so the user has to scroll to reach the bottom',
    );
  });

  testWidgets('Create Account fits the Spotlight without scrolling', (
    tester,
  ) async {
    final overflow = await _contentHeight(tester, login: false);
    expect(
      overflow,
      0.0,
      reason:
          'the create-account form needs $overflow more logical pixels '
          'than the Spotlight gives it',
    );
  });
}
