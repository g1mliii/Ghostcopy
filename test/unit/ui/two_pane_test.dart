import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/layout/two_pane.dart';

/// Which screens split the main screen into two panes.
void main() {
  bool splits(double width, double height) =>
      usesTwoPanes(width: width, shortestSide: width < height ? width : height);

  test('tablets and unfolded foldables split in either orientation', () {
    expect(splits(1032, 1376), isTrue); // 13" iPad portrait
    expect(splits(744, 1133), isTrue); // iPad mini portrait
    expect(splits(669, 951), isTrue); // iPhone Duo unfolded, upright
    expect(splits(951, 669), isTrue); // iPhone Duo unfolded, wide
    expect(splits(673, 841), isTrue); // tall Galaxy Z Fold unfolded
  });

  test('phones stay one column even when turned sideways', () {
    expect(splits(678, 466), isFalse); // iPhone Duo cover, rotated
    expect(splits(956, 440), isFalse); // Pro Max landscape
    expect(splits(440, 956), isFalse); // Pro Max portrait
    expect(splits(466, 678), isFalse); // iPhone Duo cover
  });

  test('a window narrower than two panes stays one column', () {
    expect(splits(651, 1000), isFalse);
  });
}
