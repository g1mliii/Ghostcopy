import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/window_service.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// Regression tests for clamping a grown window to the display.
///
/// The pairing dialog asks for a 700px-tall window. On a laptop whose work
/// area is shorter than that - common on Windows with display scaling - the
/// centred window ran off the top and bottom of the screen, and the content
/// could not be scrolled back: the dialog lays out against the window it was
/// given, so nothing in it ever overflowed and its scroll view had nothing to
/// scroll. The pairing controls were simply unreachable.
Display _display({
  required Size size,
  Size? visibleSize,
  Offset? visiblePosition,
  String id = 'test',
}) {
  return Display(
    id: id,
    size: size,
    visibleSize: visibleSize,
    visiblePosition: visiblePosition,
  );
}

void main() {
  group('clampHeightToDisplay', () {
    test('a short work area shrinks the request', () {
      final display = _display(
        size: const Size(1920, 720),
        visibleSize: const Size(1920, 680),
      );

      final result = WindowService.clampHeightToDisplay(700, display);

      expect(result, lessThan(700));
      expect(result, lessThanOrEqualTo(680));
    });

    test('a tall display leaves the request alone', () {
      final display = _display(
        size: const Size(2560, 1440),
        visibleSize: const Size(2560, 1400),
      );

      expect(WindowService.clampHeightToDisplay(700, display), equals(700));
    });

    test('the work area is preferred over the full display size', () {
      // The taskbar/Dock is the whole point: a window sized to the full
      // display height still ends up partly underneath it.
      final display = _display(
        size: const Size(1920, 1080),
        visibleSize: const Size(1920, 600),
      );

      expect(
        WindowService.clampHeightToDisplay(1000, display),
        lessThanOrEqualTo(600),
      );
    });

    test('falls back to the full size when no work area is reported', () {
      final display = _display(size: const Size(1280, 640));

      final result = WindowService.clampHeightToDisplay(700, display);

      expect(result, lessThanOrEqualTo(640));
    });

    test('an unknown display leaves the request untouched', () {
      // Better a slightly oversized window than refusing to resize at all.
      expect(WindowService.clampHeightToDisplay(700, null), equals(700));
    });

    test('never returns a height setSize would reject', () {
      // A work area smaller than the margin must not produce zero or less.
      final tiny = _display(
        size: const Size(400, 30),
        visibleSize: const Size(400, 30),
      );

      expect(WindowService.clampHeightToDisplay(700, tiny), greaterThan(0));
    });
  });

  group('displayContaining', () {
    final primary = _display(
      id: 'primary',
      size: const Size(1920, 1080),
      visibleSize: const Size(1920, 1040),
      visiblePosition: Offset.zero,
    );
    final secondary = _display(
      id: 'secondary',
      size: const Size(1280, 720),
      visibleSize: const Size(1280, 720),
      visiblePosition: const Offset(1920, 0),
    );

    test('picks the display the point falls on', () {
      final found = WindowService.displayContaining([
        primary,
        secondary,
      ], const Offset(2000, 300));

      // Clamping to the primary display here would size the window for a
      // screen it is not on.
      expect(found?.id, equals('secondary'));
    });

    test('picks the primary display for a point on it', () {
      final found = WindowService.displayContaining([
        primary,
        secondary,
      ], const Offset(500, 500));

      expect(found?.id, equals('primary'));
    });

    test('returns null when the point is on no display', () {
      // The caller falls back to the primary display rather than guessing.
      final found = WindowService.displayContaining([
        primary,
        secondary,
      ], const Offset(-4000, -4000));

      expect(found, isNull);
    });

    test('returns null for an empty display list', () {
      expect(WindowService.displayContaining([], const Offset(10, 10)), isNull);
    });
  });
}
