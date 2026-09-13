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

  /// Corner radius for anything that reads as a surface: the composer, clip
  /// cards, the search field.
  static const double surfaceRadius = 14;

  /// Corner radius for small controls inside a surface.
  static const double controlRadius = 10;

  /// Device selector chip height. Large enough to be a comfortable tap target
  /// without dominating the row.
  static const double chipHeight = 40;

  /// The primary action. Taller than the chips on purpose - it is the one
  /// control the whole screen is pointed at.
  static const double sendButtonHeight = 50;

  /// Minimum height of the composer when it holds nothing. Enough to read as
  /// an invitation to type rather than a single cramped line.
  static const double composerMinHeight = 132;
}
