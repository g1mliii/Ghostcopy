import '../models/clipboard_item.dart';
import 'clipboard_service.dart';

/// Service that manages clipboard synchronization in the background
///
/// This service runs continuously while the app is in the tray, handling:
/// - Realtime subscription to Supabase for incoming clipboard items
/// - Clipboard monitoring for auto-send feature
/// - Auto-receive logic (smart, always, never)
/// - Notification coordination with GameModeService
///
/// Lifecycle:
/// - Initialized once at app startup
/// - Runs continuously in background
/// - Paused/resumed based on settings (auto-send enable/disable)
/// - Disposed when app exits
abstract class IClipboardSyncService {
  /// Initialize the service (call once at startup)
  Future<void> initialize();

  /// Start clipboard monitoring for auto-send
  /// Called when user enables auto-send in settings
  void startClipboardMonitoring();

  /// Stop clipboard monitoring
  /// Called when user disables auto-send in settings
  void stopClipboardMonitoring();

  /// Get current clipboard monitoring status
  bool get isMonitoring;

  /// Callback when new clipboard item is received from another device
  /// Used by UI to refresh history
  void Function()? onClipboardReceived;

  /// Callback when clipboard is auto-sent
  /// Used by UI for feedback
  void Function(ClipboardItem item)? onClipboardSent;

  /// Update clipboard modification time
  /// Called by UI when user manually copies/pastes to track clipboard staleness
  void updateClipboardModificationTime();

  /// Notify service that content was manually sent via UI
  /// This prevents the monitor from auto-sending the same content
  void notifyManualSend(String content, {ClipboardContent? clipboardContent});

  // ========== CONNECTION MODE MANAGEMENT ==========

  /// Pause realtime subscription (keeps subscription for resume)
  void pauseRealtime();

  /// Resume realtime subscription
  void resumeRealtime();

  /// Start polling mode (HTTP polling every N minutes)
  void startPolling({Duration interval});

  /// Stop polling mode
  void stopPolling();

  /// Reinitialize realtime subscription with new user ID
  /// Call this when user logs in or switches accounts
  void reinitializeForUser();

  /// Dispose resources
  void dispose();
}
