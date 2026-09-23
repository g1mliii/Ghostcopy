import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/widgets/social_sign_in_buttons.dart';

void main() {
  Future<({List<String> taps})> pump(
    WidgetTester tester, {
    bool enabled = true,
    bool showApple = true,
  }) async {
    final taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SocialSignInButtons(
            enabled: enabled,
            showApple: showApple,
            onApple: () => taps.add('apple'),
            onGoogle: () => taps.add('google'),
          ),
        ),
      ),
    );
    return (taps: taps);
  }

  testWidgets('each logo button calls its own provider', (tester) async {
    final result = await pump(tester);

    await tester.tap(find.bySemanticsLabel('Continue with Apple'));
    await tester.tap(find.bySemanticsLabel('Continue with Google'));

    expect(result.taps, ['apple', 'google']);
  });

  testWidgets('icon-only buttons still have screen-reader labels', (
    tester,
  ) async {
    await pump(tester);

    expect(find.bySemanticsLabel('Continue with Apple'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
  });

  testWidgets('nothing fires while a sign-in is already running', (
    tester,
  ) async {
    final result = await pump(tester, enabled: false);

    await tester.tap(
      find.bySemanticsLabel('Continue with Apple'),
      warnIfMissed: false,
    );
    await tester.tap(
      find.bySemanticsLabel('Continue with Google'),
      warnIfMissed: false,
    );

    expect(result.taps, isEmpty);
  });

  testWidgets('Apple can be left out where it is not offered', (tester) async {
    await pump(tester, showApple: false);

    expect(find.bySemanticsLabel('Continue with Apple'), findsNothing);
    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
  });
}
