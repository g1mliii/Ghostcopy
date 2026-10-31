import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/theme/animations.dart';
import 'package:ghostcopy/ui/widgets/ghost_toast.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (hostContext) {
            context = hostContext;
            return const Scaffold();
          },
        ),
      ),
    );
    return context;
  }

  Future<void> finishToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets('automatically dismisses after its duration', (tester) async {
    final context = await pumpHost(tester);
    showGhostToast(context, 'Copied');
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);

    await finishToast(tester);
    expect(find.text('Copied'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces toasts inserted before their first frame', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    showGhostToast(context, 'First');
    showGhostToast(context, 'Second');
    showGhostToast(context, 'Latest');
    await tester.pumpAndSettle();

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsNothing);
    expect(find.text('Latest'), findsOneWidget);
    await finishToast(tester);
    expect(find.text('Latest'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces a mounted toast and cancels its timer', (tester) async {
    final context = await pumpHost(tester);
    showGhostToast(context, 'First');
    await tester.pumpAndSettle();
    showGhostToast(context, 'Latest', duration: const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('First'), findsNothing);
    await finishToast(tester);
    expect(find.text('Latest'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late dismissal cannot remove an already replaced toast', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    showGhostToast(context, 'First');
    await tester.pumpAndSettle();

    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.text('First'),
        matching: find.byType(FadeTransition),
      ),
    );
    var replaced = false;
    // Replace synchronously when the reverse animation finishes, before its
    // Future callback runs and before the removed widget unmounts next frame.
    fade.opacity.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        replaced = true;
        showGhostToast(context, 'Replacement');
      }
    });

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(GhostAnimations.slow);
    await tester.pumpAndSettle();

    expect(replaced, isTrue);
    expect(tester.takeException(), isNull);
    expect(find.text('First'), findsNothing);
    expect(find.text('Replacement'), findsOneWidget);

    // Also check that the old callback did not clear the replacement's owner.
    showGhostToast(context, 'Latest');
    await tester.pumpAndSettle();
    expect(find.text('Replacement'), findsNothing);
    expect(find.text('Latest'), findsOneWidget);
    await finishToast(tester);
    expect(find.text('Latest'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays clear of a side safe-area inset', (tester) async {
    // An iPhone Duo cover screen: the status strip is 84pt down the right.
    // The 320pt toast centred on 380pt would reach x = 350, under the strip.
    tester.view
      ..physicalSize = const Size(380, 800)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(right: 84);
    addTearDown(tester.view.reset);

    final context = await pumpHost(tester);
    showGhostToast(context, 'A message long enough to want the full width');
    await tester.pumpAndSettle();

    final toast = tester.getRect(
      find
          .ancestor(
            of: find.textContaining('A message'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(toast.left, greaterThanOrEqualTo(0));
    expect(toast.right, lessThanOrEqualTo(380 - 84));
    await finishToast(tester);
  });

  testWidgets('can show a toast after its previous overlay is disposed', (
    tester,
  ) async {
    var context = await pumpHost(tester);
    showGhostToast(context, 'First');
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());

    context = await pumpHost(tester);
    showGhostToast(context, 'Latest');
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsOneWidget);
    await finishToast(tester);
    expect(find.text('Latest'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
