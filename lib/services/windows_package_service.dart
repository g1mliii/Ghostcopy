/// What Windows reports about GhostCopy's startup task.
///
/// Mirrors `Windows.ApplicationModel.StartupTaskState` one for one, with
/// [unavailable] added for the cases the WinRT type cannot answer at all: an
/// unpackaged build, or a failure reaching the manifest. Sent across the
/// channel as a string so that adding a state later cannot renumber the rest -
/// see `StartupStateName` in `windows/runner/flutter_window.cpp`.
enum WindowsStartupState {
  unavailable,
  disabled,
  disabledByUser,
  disabledByPolicy,
  enabled,
  enabledByPolicy;

  /// Whether the app actually launches at login in this state.
  bool get isOn =>
      this == WindowsStartupState.enabled ||
      this == WindowsStartupState.enabledByPolicy;

  /// Whether asking Windows to change it is pointless. Once the user turns the
  /// entry off in Task Manager's Startup tab, that decision is theirs to undo
  /// and `RequestEnableAsync` will not override it; policy is the same but set
  /// by an administrator. A settings UI should say so rather than offer a
  /// toggle that silently does nothing.
  bool get isLockedByOther =>
      this == WindowsStartupState.disabledByUser ||
      this == WindowsStartupState.disabledByPolicy ||
      this == WindowsStartupState.enabledByPolicy;
}

/// Windows packaging facts, and the startup task that replaces the Run key.
///
/// GhostCopy registers three things for itself at first run - the
/// `ghostcopy://` scheme, the "Send with GhostCopy" Explorer entry, and launch
/// at startup - and all three write to `HKCU`. Inside an MSIX package those
/// writes are virtualized into a private per-package hive: they report success
/// and nothing outside the package ever sees them. So each one needs its
/// manifest-declared equivalent instead, and [isPackaged] is how the app knows
/// which of the two it is.
abstract class IWindowsPackageService {
  /// True when running from inside an MSIX package. False on every other
  /// platform, and for an unpackaged Windows build.
  Future<bool> isPackaged();

  /// The current state of the packaged startup task.
  Future<WindowsStartupState> startupState();

  /// Asks Windows to enable launch at login, and returns the state that
  /// resulted - which is not necessarily [WindowsStartupState.enabled], since
  /// a user or policy refusal wins.
  Future<WindowsStartupState> enableStartup();

  /// Disables launch at login, and returns the state that resulted.
  Future<WindowsStartupState> disableStartup();
}
