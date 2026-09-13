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
  static const double historyRowMinHeight = 75;

  /// The primary action. Taller than the chips on purpose - it is the one
  /// control the whole screen is pointed at.
  static const double sendButtonHeight = 50;

  /// Gap between the composer, the destination row and the send button.
  static const double sectionLoose = 25;
}
