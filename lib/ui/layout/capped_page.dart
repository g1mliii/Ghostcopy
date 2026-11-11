import 'package:flutter/widgets.dart';

/// A page as tall as what is on it, up to [maxHeight].
///
/// The collapsed mobile page: history folded away, the composer free to grow
/// with its text. A [Flexible] child takes only what it needs and at most the
/// room the others leave, so an empty composer stays a few lines tall, a long
/// one stops at the cap and scrolls inside itself, and the controls under it
/// stay on the page in both cases.
///
/// Its own widget so the layout rules can be tested without the whole screen.
/// A fixed height left blank space to scroll into under a short composer;
/// SliverFillRemaining sized to the composer's full text, so a long paste
/// pushed Send off the screen. Both shipped once.
class CappedPage extends StatelessWidget {
  const CappedPage({
    required this.maxHeight,
    required this.children,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final double maxHeight;
  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
