import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/tray_menu_lifecycle.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  int warmUpFrames = 0;

  @override
  void scheduleWarmUpFrame() {
    warmUpFrames++;
    super.scheduleWarmUpFrame();
  }
}

void main() {
  final binding = _Binding();

  testWidgets('hidden window draws the menu before its native show', (
    tester,
  ) async {
    final showingMenu = ValueNotifier(false);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<bool>(
          valueListenable: showingMenu,
          builder: (context, value, child) =>
              Text(value ? 'Mini tray menu' : 'Full app'),
        ),
      ),
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(binding.framesEnabled, isFalse);
    final before = binding.warmUpFrames;

    showingMenu.value = true;
    final transition = renderTrayTransitionFrame();
    expect(binding.warmUpFrames, before + 1);
    await tester.pump();
    await transition;

    expect(find.text('Mini tray menu'), findsOneWidget);
    expect(find.text('Full app'), findsNothing);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    showingMenu.dispose();
  });

  test('hide and resize blur cannot dismiss a menu still opening', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => false,
        onDismiss: () => dismissed++,
      );
      final revision = menu.beginOpening();

      menu.onWindowBlur();
      async.elapse(const Duration(seconds: 2));
      menu.onWindowBlur();

      expect(dismissed, 0);
      expect(menu.isCurrent(revision), isTrue);
      menu
        ..finishOpening(revision)
        ..dispose();
    });
  });

  test('reopening does not reuse the previous menu blur timestamp', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => false,
        onDismiss: () => dismissed++,
      );
      menu.finishOpening(menu.beginOpening());
      async.elapse(const Duration(seconds: 2));
      menu.close();

      final revision = menu.beginOpening();
      menu.onWindowBlur();
      async.elapse(const Duration(seconds: 1));

      expect(dismissed, 0);
      expect(menu.isCurrent(revision), isTrue);
      menu.dispose();
    });
  });

  test('clicking away within the grace still dismisses after it', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => false,
        onDismiss: () => dismissed++,
      );
      menu.finishOpening(menu.beginOpening());
      async.elapse(const Duration(milliseconds: 100));
      menu.onWindowBlur();
      async.elapse(const Duration(milliseconds: 399));
      expect(dismissed, 0);
      async
        ..elapse(const Duration(milliseconds: 1))
        ..flushMicrotasks();
      expect(dismissed, 1);
      menu.dispose();
    });
  });

  test('overflow flyout blur leaves the focused menu open', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => true,
        onDismiss: () => dismissed++,
      );
      menu
        ..finishOpening(menu.beginOpening())
        ..onWindowBlur();
      async
        ..elapse(const Duration(seconds: 1))
        ..flushMicrotasks();
      expect(dismissed, 0);
      menu.dispose();
    });
  });

  test('a stale focus response cannot dismiss a newly opened menu', () {
    fakeAsync((async) {
      var dismissed = 0;
      final focus = Completer<bool>();
      final menu = TrayMenuLifecycle(
        isFocused: () => focus.future,
        onDismiss: () => dismissed++,
      );
      menu
        ..finishOpening(menu.beginOpening())
        ..onWindowBlur();
      async.elapse(const Duration(milliseconds: 500));

      menu.finishOpening(menu.beginOpening());
      focus.complete(false);
      async.flushMicrotasks();

      expect(dismissed, 0);
      menu.dispose();
    });
  });

  test('close invalidates an opener and cancels delayed dismissal', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => false,
        onDismiss: () => dismissed++,
      );
      final revision = menu.beginOpening();
      menu
        ..finishOpening(revision)
        ..onWindowBlur()
        ..close()
        ..finishOpening(revision);
      async
        ..elapse(const Duration(seconds: 1))
        ..flushMicrotasks();

      expect(menu.isCurrent(revision), isFalse);
      expect(dismissed, 0);
      menu.dispose();
    });
  });

  test('a normal click away after the grace dismisses immediately', () {
    fakeAsync((async) {
      var dismissed = 0;
      final menu = TrayMenuLifecycle(
        isFocused: () async => true,
        onDismiss: () => dismissed++,
      );
      menu.finishOpening(menu.beginOpening());
      async.elapse(const Duration(seconds: 1));
      menu.onWindowBlur();
      expect(dismissed, 1);
      menu.dispose();
    });
  });
}
