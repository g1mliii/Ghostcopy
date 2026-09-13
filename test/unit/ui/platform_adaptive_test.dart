import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/platform_adaptive.dart';
import 'package:ghostcopy/ui/theme/typography.dart';

/// These run on the host (Windows here), so they pin the NON-Apple branch.
/// Adaptive reads dart:io's Platform, which - unlike TargetPlatform - cannot be
/// overridden from a test, so the iOS branches are only verifiable on a device.
/// What these do catch is the regression that actually matters: a "native on
/// iOS" change leaking onto every other platform.
void main() {
  final isApple = Platform.isIOS || Platform.isMacOS;

  group('Adaptive', () {
    test('isIOS and isApple agree with the host platform', () {
      expect(Adaptive.isIOS, Platform.isIOS);
      expect(Adaptive.isApple, isApple);
    });

    test('pageRoute picks the platform route type', () {
      final route = Adaptive.pageRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      if (Platform.isIOS) {
        expect(route, isA<CupertinoPageRoute<void>>());
      } else {
        expect(route, isA<MaterialPageRoute<void>>());
      }
    });

    test('scrollPhysics always allows scrolling so pull-to-refresh works', () {
      final physics = Adaptive.scrollPhysics;
      expect(
        physics,
        isApple ? isA<BouncingScrollPhysics>() : isA<ClampingScrollPhysics>(),
      );
      // A list shorter than its viewport must still accept the overscroll drag
      // that drives RefreshIndicator - that is what the AlwaysScrollable
      // parent is for, and dropping it silently kills pull-to-refresh.
      expect(
        physics.shouldAcceptUserOffset(
          FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 0,
            pixels: 0,
            viewportDimension: 600,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 1,
          ),
        ),
        isTrue,
      );
    });

    test('haptics do not throw when no engine is attached', () {
      expect(Adaptive.successFeedback, returnsNormally);
      expect(Adaptive.impactFeedback, returnsNormally);
    });
  });

  group('GhostTypography', () {
    test('uses SF Pro / Menlo on Apple and the design font elsewhere', () {
      if (isApple) {
        expect(GhostTypography.uiFontFamily, '.SF Pro Text');
        expect(GhostTypography.codeFontFamily, 'Menlo');
      } else {
        expect(GhostTypography.uiFontFamily, GhostTypography.fontFamily);
        expect(GhostTypography.codeFontFamily, GhostTypography.monoFontFamily);
      }
    });

    test('text styles carry the resolved family, not the literal', () {
      for (final style in [
        GhostTypography.headline,
        GhostTypography.body,
        GhostTypography.caption,
      ]) {
        expect(style.fontFamily, GhostTypography.uiFontFamily);
      }
      expect(GhostTypography.mono.fontFamily, GhostTypography.codeFontFamily);
    });
  });
}
