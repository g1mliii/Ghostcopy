/// System power state monitoring service
///
/// Detects system sleep, wake, screen lock, and unlock events
/// for lifecycle management and connection optimization.
abstract class ISystemPowerService {
  /// Stream of power events (sleep, wake, lock, unlock)
  Stream<PowerEvent> get powerEventStream;

  /// Initialize platform-specific power monitoring
  Future<void> initialize();

  /// Dispose and cleanup resources
  void dispose();
}

/// Types of system power events
enum PowerEventType {
  /// System is going to sleep or hibernate
  systemSleep,

  /// System has woken up from sleep or hibernate
  systemWake,

  /// Screen has been locked
  screenLock,

  /// Screen has been unlocked
  screenUnlock,
}

/// Power event with timestamp
class PowerEvent {
  PowerEvent(this.type) : timestamp = DateTime.now();

  final PowerEventType type;
  final DateTime timestamp;

  @override
  String toString() => 'PowerEvent(${type.name} at $timestamp)';
}
