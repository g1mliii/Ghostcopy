import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/hotkey_service.dart';
import 'package:ghostcopy/services/impl/hotkey_service.dart';
import 'package:ghostcopy/ui/widgets/hotkey_capture_field.dart';

/// End-to-end capture test for the shortcut field.
///
/// The helper map is unit tested next door; this drives the real widget, so
/// it fails if the normalization is present but never consulted by the key
/// handler - which is how the bug would come back.
void main() {
  Future<HotKey?> capture(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys,
  ) async {
    HotKey? captured;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HotkeyCapture(
            currentHotkey: const HotKey(key: 's', ctrl: true, shift: true),
            onHotkeyChanged: (hotkey) => captured = hotkey,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Change'));
    await tester.pump();

    for (final key in keys) {
      await tester.sendKeyDownEvent(key);
    }
    await tester.pump();

    return captured;
  }

  testWidgets('Option+Space is captured as the stored default', (tester) async {
    final captured = await capture(tester, [
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.space,
    ]);

    // The field used to emit HotKey(key: " ") here, which convertKey trims to
    // an empty string and refuses - so the macOS default could not be set
    // back once the user had changed it.
    expect(captured, isNotNull);
    expect(captured, equals(const HotKey(key: 'space', alt: true)));
    expect(HotkeyService.convertKey(captured!.key), isNotNull);
  });

  testWidgets('a letter is still captured normally', (tester) async {
    final captured = await capture(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.keyK,
    ]);

    expect(captured, equals(const HotKey(key: 'k', ctrl: true, shift: true)));
  });

  testWidgets('a function key is captured', (tester) async {
    final captured = await capture(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.f5,
    ]);

    expect(captured, equals(const HotKey(key: 'f5', ctrl: true)));
    expect(HotkeyService.convertKey(captured!.key), isNotNull);
  });

  testWidgets('a bare key without a modifier is not captured', (tester) async {
    final captured = await capture(tester, [LogicalKeyboardKey.space]);

    expect(captured, isNull);
  });
}
