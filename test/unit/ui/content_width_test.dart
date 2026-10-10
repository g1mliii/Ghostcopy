import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/theme/spacing.dart';

void main() {
  test('phones keep the full width: the floor is above them', () {
    // A cap wider than the screen leaves the column at the screen's width.
    expect(GhostSpacing.contentWidthFor(402), greaterThan(402));
  });

  test('tablets take most of the width, within bounds', () {
    expect(GhostSpacing.contentWidthFor(800), 640); // the floor
    expect(GhostSpacing.contentWidthFor(834), closeTo(667.2, 0.01));
    expect(GhostSpacing.contentWidthFor(1032), closeTo(825.6, 0.01));
    expect(GhostSpacing.contentWidthFor(1600), 880); // the ceiling
  });
}
