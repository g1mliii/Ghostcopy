import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/layout/side_safe_area.dart';

/// The iPhone Duo's status strip runs down the right edge of the screen, and
/// content laid out under it is drawn over.
void main() {
  Future<void> pumpWithPadding(WidgetTester tester, EdgeInsets padding) =>
      tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: const Size(466, 900), padding: padding),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SideSafeArea(child: SizedBox.expand(key: Key('content'))),
          ),
        ),
      );

  testWidgets('keeps content out of a right-edge status strip', (tester) async {
    tester.view.physicalSize = const Size(466, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpWithPadding(tester, const EdgeInsets.only(right: 84));

    final rect = tester.getRect(find.byKey(const Key('content')));
    expect(rect.left, 0);
    expect(rect.right, 466 - 84);
  });

  testWidgets('leaves top and bottom to the screens', (tester) async {
    tester.view.physicalSize = const Size(466, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpWithPadding(
      tester,
      const EdgeInsets.only(left: 47, top: 59, bottom: 34),
    );

    final rect = tester.getRect(find.byKey(const Key('content')));
    expect(rect, const Rect.fromLTRB(47, 0, 466, 900));

    // The AppBar still sees the status bar and grows into it.
    final inner = tester.element(find.byKey(const Key('content')));
    expect(
      MediaQuery.paddingOf(inner),
      const EdgeInsets.only(top: 59, bottom: 34),
    );
  });
}
