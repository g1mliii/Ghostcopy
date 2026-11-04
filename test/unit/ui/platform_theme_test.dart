import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/theme/app_theme.dart';
import 'package:ghostcopy/ui/theme/colors.dart';

void main() {
  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    testWidgets('palette and keyboard appearance on $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final mobile = platform != TargetPlatform.windows;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.platformTheme,
          home: const Scaffold(body: TextField()),
        ),
      );
      final context = tester.element(find.byType(TextField));
      final theme = Theme.of(context);
      expect(theme.brightness, mobile ? Brightness.light : Brightness.dark);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .keyboardAppearance,
        theme.brightness,
      );
      expect(
        theme.scaffoldBackgroundColor,
        mobile ? const Color(0xFFF2F2F7) : const Color(0xFF0F0F13),
      );
      expect(
        theme.cardTheme.color,
        mobile ? Colors.white : const Color(0xFF19191F),
      );
      expect(theme.dialogTheme.backgroundColor, theme.cardTheme.color);
      for (final color in [
        GhostColors.textPrimary,
        GhostColors.textSecondary,
        GhostColors.textMuted,
        GhostColors.accentText,
      ]) {
        final surface = color == GhostColors.accentText
            ? GhostColors.accentSoft
            : GhostColors.surface;
        final luminances = [
          color.computeLuminance(),
          surface.computeLuminance(),
        ]..sort();
        expect(
          (luminances.last + 0.05) / (luminances.first + 0.05),
          greaterThanOrEqualTo(4.5),
        );
      }
      if (mobile) {
        for (final pair in [
          (
            theme.inputDecorationTheme.hintStyle!.color!,
            theme.inputDecorationTheme.fillColor!,
          ),
          (GhostColors.textMuted, GhostColors.surfaceLight),
          (GhostColors.warningText, GhostColors.surface),
          (GhostColors.errorText, GhostColors.surface),
          (
            GhostColors.successText,
            Color.alphaBlend(
              GhostColors.success.withValues(alpha: 0.2),
              GhostColors.surface,
            ),
          ),
        ]) {
          final luminances = [
            pair.$1.computeLuminance(),
            pair.$2.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + 0.05) / (luminances.first + 0.05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
