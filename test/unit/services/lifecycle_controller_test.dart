import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/impl/lifecycle_controller.dart';
import 'package:ghostcopy/services/lifecycle_controller.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettingsService extends Mock implements ISettingsService {}

/// Records only what the lifecycle controller drives.
class _RecordingSyncService implements IClipboardSyncService {
  @override
  void ensureRealtimeConnected() {}

  bool polling = false;
  bool realtimePaused = false;

  @override
  bool get isMonitoring => false;

  @override
  void Function()? onClipboardReceived;

  @override
  void Function(ClipboardItem item)? onClipboardSent;

  @override
  Future<void> initialize() async {}

  @override
  void notifyManualSend(String content, {ClipboardContent? clipboardContent}) {}

  @override
  void pauseRealtime() => realtimePaused = true;

  @override
  void reinitializeForUser() {}

  @override
  void resumeRealtime() => realtimePaused = false;

  int monitoringStarts = 0;

  @override
  void startClipboardMonitoring() => monitoringStarts++;

  @override
  void startPolling({Duration interval = const Duration(minutes: 5)}) {
    polling = true;
  }

  @override
  void stopClipboardMonitoring() {}

  @override
  void stopPolling() => polling = false;

  @override
  void updateClipboardModificationTime() {}

  /// How often the lifecycle stopped / re-checked the staleness watch.
  int activityWatchStops = 0;
  int activityWatchRefreshes = 0;

  @override
  Future<void> refreshClipboardActivityWatch() async =>
      activityWatchRefreshes++;

  @override
  void stopClipboardActivityWatch() => activityWatchStops++;

  @override
  void dispose() {}
}

/// Regression tests for hybrid-mode connection switching.
///
/// The idle calculation fell back to Duration.zero whenever there had been no
/// clipboard activity yet, which reads as "active right now" - so a session
/// where the user never copied anything stayed on the websocket forever and
/// never dropped to polling, which is exactly the session polling is for.
void main() {
  late _MockSettingsService settings;
  late _RecordingSyncService sync;

  setUp(() {
    settings = _MockSettingsService();
    sync = _RecordingSyncService();
    when(settings.isHybridModeEnabled).thenAnswer((_) async => true);
    when(settings.getAutoSendEnabled).thenAnswer((_) async => false);
  });

  // Every way the window hides goes through enterTrayMode. The trim used to
  // live in the Spotlight's blur handler, which only one of them reached.
  test('tray mode trims the working set once the window has settled', () {
    fakeAsync((async) {
      var trims = 0;
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
        trimWorkingSet: () async => trims++,
      )..enterTrayMode();
      async.elapse(const Duration(seconds: 1));
      expect(trims, 0, reason: 'delayed until the window has gone');
      async.elapse(const Duration(seconds: 2));
      expect(trims, 1);

      // Reopened inside the delay: the visible window keeps its pages.
      controller
        ..exitTrayMode()
        ..enterTrayMode();
      async.elapse(const Duration(seconds: 1));
      controller.exitTrayMode();
      async.elapse(const Duration(seconds: 5));
      expect(trims, 1);
      controller.dispose();
    });
  });

  test('screen lock stops the staleness watch and unlock restarts it', () {
    fakeAsync((async) {
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
      )..initialize();
      async.elapse(const Duration(seconds: 1));

      controller.onScreenLock();
      expect(sync.activityWatchStops, 1);

      controller.onScreenUnlock();
      async.elapse(const Duration(seconds: 1));
      expect(sync.activityWatchRefreshes, 1);

      controller.dispose();
    });
  });

  test('a lock during the unlock resume does not restart monitoring', () {
    fakeAsync((async) {
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
      )..initialize();
      async.elapse(const Duration(seconds: 1));

      controller.onScreenLock();
      final autoSend = Completer<bool>();
      when(settings.getAutoSendEnabled).thenAnswer((_) => autoSend.future);
      controller
        ..onScreenUnlock()
        ..onScreenLock();
      autoSend.complete(true);
      async.elapse(const Duration(seconds: 1));

      expect(sync.monitoringStarts, 0);
      controller.dispose();
    });
  });

  test('switches to polling after idling in the tray with no activity', () {
    fakeAsync((async) {
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
      )..initialize();

      // Let initialize() settle so the inactivity timer is running.
      async.elapse(const Duration(seconds: 1));

      controller.enterTrayMode();

      // Past the 15-minute threshold, with the inactivity check running every
      // two minutes.
      async.elapse(const Duration(minutes: 20));

      expect(
        controller.connectionMode,
        ConnectionMode.polling,
        reason: 'idle in tray past the threshold should drop the websocket',
      );
      expect(sync.polling, isTrue);
      expect(sync.realtimePaused, isTrue);

      controller.dispose();
      async.flushTimers();
    });
  });

  test('stays on realtime while the window is open', () {
    fakeAsync((async) {
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
      )..initialize();

      // Settle init, then idle well past the threshold. No enterTrayMode:
      // the window stays visible, which is what should keep it on realtime.
      async
        ..elapse(const Duration(seconds: 1))
        ..elapse(const Duration(minutes: 20));

      expect(controller.connectionMode, ConnectionMode.realtime);
      expect(sync.polling, isFalse);

      controller.dispose();
      async.flushTimers();
    });
  });

  test('clipboard activity brings it back to realtime', () {
    fakeAsync((async) {
      final controller = LifecycleController(
        clipboardSyncService: sync,
        settingsService: settings,
      )..initialize();

      async.elapse(const Duration(seconds: 1));

      controller.enterTrayMode();

      async.elapse(const Duration(minutes: 20));
      expect(controller.connectionMode, ConnectionMode.polling);

      controller.notifyClipboardActivity();

      expect(controller.connectionMode, ConnectionMode.realtime);
      expect(sync.polling, isFalse);
      expect(sync.realtimePaused, isFalse);

      controller.dispose();
      async.flushTimers();
    });
  });
}
