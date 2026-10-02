/// How the Spotlight behaves when focus moves to another window.
///
/// One button cycles through these. Two kinds of pin because "stay open" and
/// "stay on top" are different wants: on a laptop, a window that floats over
/// everything covers the work it was pinned to help with.
enum SpotlightPin {
  /// Hides when clicking away, as Spotlight-style launchers do. The default.
  off,

  /// Stays open as an ordinary window: other apps can cover it, and the
  /// hotkey or the tray icon brings it back to the front.
  open,

  /// Stays open above every other window.
  onTop;

  /// The click order: off, pinned, pinned on top, and off again.
  SpotlightPin get next =>
      SpotlightPin.values[(index + 1) % SpotlightPin.values.length];

  /// A saved name back to a pin; anything unrecognised is off.
  static SpotlightPin fromName(String? name) => SpotlightPin.values.firstWhere(
    (pin) => pin.name == name,
    orElse: () => SpotlightPin.off,
  );
}
