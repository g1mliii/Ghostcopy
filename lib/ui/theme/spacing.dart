/// Layout constants for the mobile UI.
///
/// These existed only as literals scattered through the widget tree - 20 here,
/// 16 there, 12 somewhere else - so nothing lined up down the page and every
/// new widget picked a fresh number. Naming them makes the rhythm enforceable
/// and gives a single place to change it.
class GhostSpacing {
  const GhostSpacing._();

  /// Distance from the screen edge to any content. One value everywhere, so
  /// the composer, chips, send button and history rows share a left edge.
  static const double gutter = 16;

  /// Vertical gap between major sections (composer -> chips -> send).
  static const double section = 16;

  /// Tighter gap for elements that belong to the same group.
  static const double sectionTight = 12;

  /// Corner radius for anything that reads as a surface: the composer, the
  /// grouped history list, the empty state.
  static const double surfaceRadius = 16;

  /// Slightly tighter radius for the grouped list's inner clip, so rows do not
  /// show a sliver of the container behind their corners.
  static const double surfaceRadiusInner = 14;

  /// Corner radius for chips. Matches the desktop Spotlight's platform chips,
  /// so the same control reads the same on both platforms.
  static const double chipRadius = 6;

  /// Corner radius for the search field and other inline controls.
  static const double controlRadius = 10;

  /// Corner radius for the primary button, matching desktop's send button.
  static const double buttonRadius = 8;

  /// Corner radius for a thumbnail inside a row.
  static const double thumbRadius = 10;

  /// Destination chip height.
  static const double chipHeight = 38;

  /// Minimum tap target. Anything interactive must reach this in both axes.
  static const double minTouchTarget = 44;

  /// Image thumbnail in a history row. Small on purpose: full-width previews
  /// made a couple of screenshots fill the whole list.
  static const double thumbSize = 52;

  /// Minimum height of a history row.
  /// Floor for a history row, so single-line clips do not collapse to a thin
  /// strip beside the two-line ones. Raised with the clip type: at 75 a row
  /// holding two lines of 15px text plus a meta line had no room left, which is
  /// what made the list read as cramped on a large screen.
  static const double historyRowMinHeight = 84;

  /// The primary action. Taller than the chips on purpose - it is the one
  /// control the whole screen is pointed at.
  static const double sendButtonHeight = 50;

  /// Gap between the composer, the destination row and the send button.
  static const double sectionLoose = 25;

  /// How wide the mobile content column gets on a screen [available] wide.
  ///
  /// Phones are narrower than the floor, so they stay full width. Tablets are
  /// not: the layout is one column of full-bleed cards, and uncapped, a line
  /// of clip text ran the whole way across and the composer became a very
  /// wide, very short box. A flat 640 fixed that but went too far the other
  /// way - on a 13" iPad in portrait it left nearly 200 of empty margin each
  /// side, close to 40% of the screen. So the column takes most of the width,
  /// within bounds that keep it readable:
  ///
  ///   Android tablet  800 wide -> 640 (the floor)
  ///   11" iPad        834 wide -> 667
  ///   13" iPad       1032 wide -> 826
  ///   wider                     -> 880 (the ceiling)
  static double contentWidthFor(double available) =>
      (available * _contentWidthShare).clamp(
        _contentWidthMin,
        _contentWidthMax,
      );

  static const double _contentWidthShare = 0.8;
  static const double _contentWidthMin = 640;
  static const double _contentWidthMax = 880;
}
