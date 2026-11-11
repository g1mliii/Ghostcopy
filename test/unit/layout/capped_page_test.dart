import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/layout/capped_page.dart';

/// The collapsed mobile page's layout rules, with a composer configured as
/// mobile_main_screen's is when history is folded away.
void main() {
  const maxHeight = 600.0;
  const controlsHeight = 200.0;
  final composer = find.byKey(const ValueKey('composer'));
  final controls = find.byKey(const ValueKey('controls'));
  final page = find.byType(CappedPage);

  Future<void> pumpPage(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CappedPage(
              maxHeight: maxHeight,
              children: [
                Flexible(
                  child: TextField(
                    key: const ValueKey('composer'),
                    controller: TextEditingController(text: text),
                    minLines: 3,
                    maxLines: null,
                  ),
                ),
                const SizedBox(
                  key: ValueKey('controls'),
                  height: controlsHeight,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('an empty composer stays short, with no blank page under it', (
    tester,
  ) async {
    await pumpPage(tester, '');

    final composerHeight = tester.getSize(composer).height;
    expect(composerHeight, lessThan(120));
    expect(
      tester.getSize(page).height,
      moreOrLessEquals(composerHeight + controlsHeight),
    );
  });

  testWidgets('a long text stops at the cap and keeps the controls on the '
      'page', (tester) async {
    await pumpPage(tester, List.filled(400, 'line').join('\n'));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(page).height, moreOrLessEquals(maxHeight));
    expect(
      tester.getSize(composer).height,
      moreOrLessEquals(maxHeight - controlsHeight),
    );
    expect(
      tester.getBottomLeft(controls).dy,
      lessThanOrEqualTo(tester.getBottomLeft(page).dy),
    );
  });

  testWidgets('the composer grows with its text below the cap', (tester) async {
    await pumpPage(tester, '');
    final empty = tester.getSize(composer).height;
    await pumpPage(tester, List.filled(8, 'line').join('\n'));

    final grown = tester.getSize(composer).height;
    expect(grown, greaterThan(empty));
    expect(grown, lessThan(maxHeight - controlsHeight));
  });
}
