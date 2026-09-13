import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/theme/app_theme.dart';
import 'package:ghostcopy/ui/theme/colors.dart';
import 'package:ghostcopy/ui/theme/spacing.dart';
import 'package:ghostcopy/ui/theme/typography.dart';

/// Renders the mobile send screen's chrome so it can be inspected as pixels.
///
/// The emulator cannot screenshot this app - Android's screencap returns a
/// black frame because Flutter's surface is a hardware overlay - which left
/// every visual change unverifiable. A golden renders the same widgets in a
/// headless canvas, where the pixels ARE readable.
///
/// Run: flutter test --update-goldens test/golden/mobile_visual_test.dart
void main() {
  testWidgets('mobile send screen chrome', (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 1600)
      ..devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: Scaffold(
          backgroundColor: GhostColors.background,
          appBar: AppBar(
            toolbarHeight: 62,
            titleSpacing: GhostSpacing.gutter,
            backgroundColor: GhostColors.background,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            title: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: GhostColors.primary,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'GhostCopy',
                  style: GhostTypography.headline.copyWith(
                    fontSize: 17,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () {},
                color: GhostColors.textMuted,
                tooltip: 'Settings',
              ),
              const SizedBox(width: 1),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              GhostSpacing.gutter,
              8,
              GhostSpacing.gutter,
              24,
            ),
            children: [
              // Composer
              DecoratedBox(
                decoration: BoxDecoration(
                  color: GhostColors.surface,
                  borderRadius: BorderRadius.circular(
                    GhostSpacing.surfaceRadius,
                  ),
                  border: Border.all(color: GhostColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                      child: Text(
                        'Paste or type something…',
                        style: TextStyle(
                          fontSize: 16,
                          color: GhostColors.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    const Divider(height: 1, color: GhostColors.border),
                    Padding(
                      // 14 here plus Material's 2dp inset inside a zero-padding
      // TextButton.icon puts the Attach glyph at 16dp - the same left edge as
      // the text above it and the history rows below. Measured from rendered
      // pixels rather than derived, because the button's internal geometry is
      // not obvious from its API.
      padding: const EdgeInsets.fromLTRB(14, 4, 12, 5),
                      child: Row(
                        children: [
                          TextButton.icon(
                            onPressed: () {},
                            icon: const Icon(
                              Icons.attach_file_rounded,
                              size: 17,
                            ),
                            label: const Text('Attach'),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              foregroundColor: GhostColors.textMuted,
                            ),
                          ),
                          const Spacer(),
                          const Flexible(
                            child: Text(
                              'Nothing to send yet',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: GhostColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              // Chips
              SizedBox(
                height: GhostSpacing.chipHeight,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _chip('All devices', Icons.devices_rounded, true),
                    const SizedBox(width: 8),
                    _chip('Windows', Icons.laptop_windows, false),
                    const SizedBox(width: 8),
                    _chip('Android', Icons.phone_android, false),
                  ],
                ),
              ),
              const SizedBox(height: 13),
              // Send button
              SizedBox(
                height: GhostSpacing.sendButtonHeight,
                child: FilledButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send to all devices'),
                  style: FilledButton.styleFrom(
                    backgroundColor: GhostColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        GhostSpacing.buttonRadius,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: GhostSpacing.sectionLoose),
              // History
              Row(
                children: [
                  Text(
                    'Clipboard history',
                    style: GhostTypography.headline.copyWith(fontSize: 15),
                  ),
                  const SizedBox(width: 7),
                  const Text(
                    '3 recent',
                    style: TextStyle(
                      fontSize: 12,
                      color: GhostColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 46,
                decoration: BoxDecoration(
                  color: GhostColors.surface,
                  borderRadius: BorderRadius.circular(
                    GhostSpacing.controlRadius,
                  ),
                  border: Border.all(color: GhostColors.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                child: const Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: GhostColors.textMuted,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Search clips…',
                      style: TextStyle(color: GhostColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: GhostSpacing.sectionTight),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: GhostColors.surface,
                  borderRadius: BorderRadius.circular(
                    GhostSpacing.surfaceRadius,
                  ),
                  border: Border.all(color: GhostColors.border),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    GhostSpacing.surfaceRadiusInner,
                  ),
                  child: Column(
                    children: [
                      _row('Some copied text from the desktop app', null),
                      const Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: GhostColors.border,
                      ),
                      _row('report.pdf', Icons.picture_as_pdf),
                      const Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: GhostColors.border,
                      ),
                      _row('notes.txt', Icons.text_snippet),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('mobile_send_screen.png'),
    );
    // Skipped in normal runs on purpose. This is a diagnostic for LOOKING at
    // the design - the emulator cannot screenshot this app, so a golden is the
    // only way to see rendered pixels. It is not a regression gate: the test
    // environment substitutes a fixed-width fallback font whose glyphs are far
    // wider than the real ones, so text-dependent layout differs from the
    // device and would fail for reasons that say nothing about the app.
    //
    // To look at the current design:
    //   flutter test --update-goldens test/golden/mobile_visual_test.dart
    // then open test/golden/mobile_send_screen.png
  }, skip: true);
}

Widget _chip(String label, IconData icon, bool selected) {
  return Material(
    color: selected ? GhostColors.accentSoft : GhostColors.surface,
    borderRadius: BorderRadius.circular(GhostSpacing.chipRadius),
    child: Container(
      height: GhostSpacing.chipHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GhostSpacing.chipRadius),
        border: Border.all(
          color: selected ? GhostColors.accentBorder : GhostColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: selected ? GhostColors.accentText : GhostColors.textMuted,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected ? GhostColors.accentText : GhostColors.textMuted,
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _row(String preview, IconData? fileIcon) {
  return ConstrainedBox(
    constraints: const BoxConstraints(
      minHeight: GhostSpacing.historyRowMinHeight,
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 3, 10),
      child: Row(
        children: [
          if (fileIcon != null) ...[
            Container(
              width: GhostSpacing.thumbSize,
              height: GhostSpacing.thumbSize,
              decoration: BoxDecoration(
                color: GhostColors.surfaceLight,
                borderRadius: BorderRadius.circular(GhostSpacing.thumbRadius),
              ),
              child: Icon(fileIcon, color: GhostColors.accentText, size: 23),
            ),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: GhostColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 7),
                const Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 5,
                  children: [
                    Icon(
                      Icons.laptop_windows,
                      size: 12,
                      color: GhostColors.textMuted,
                    ),
                    Text(
                      'Windows',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.textMuted,
                      ),
                    ),
                    Text(
                      '•',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.textMuted,
                      ),
                    ),
                    Text(
                      '2m',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.textMuted,
                      ),
                    ),
                    Text(
                      '→',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.textMuted,
                      ),
                    ),
                    Text(
                      'All devices',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.accentText,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(
            Icons.copy_rounded,
            size: 18,
            color: GhostColors.textMuted,
          ),
          const SizedBox(width: 12),
        ],
      ),
    ),
  );
}
