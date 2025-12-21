import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/services/game_mode_service.dart';
import 'package:ghostcopy/services/impl/game_mode_service.dart';

void main() {
  group('GameModeService', () {
    late IGameModeService gameModeService;

    setUp(() {
      gameModeService = GameModeService();
    });

    tearDown(() {
      gameModeService.dispose();
    });

    ClipboardItem createTestItem(String content) {
      return ClipboardItem(
        id: '1',
        userId: 'test-user',
        content: content,
        deviceType: 'windows',
        createdAt: DateTime.now(),
      );
    }

    group('Initial State', () {
      test('should start with Game Mode inactive', () {
        expect(gameModeService.isActive, isFalse);
      });

      test('should have empty queue initially', () {
        final items = gameModeService.flushQueue();
        expect(items, isEmpty);
      });
    });

    group('Toggle Functionality', () {
      test('should toggle from inactive to active', () {
        expect(gameModeService.isActive, isFalse);
        gameModeService.toggle();
        expect(gameModeService.isActive, isTrue);
      });

      test('should toggle from active to inactive', () {
        gameModeService.toggle(); // activate
        expect(gameModeService.isActive, isTrue);
        gameModeService.toggle(); // deactivate
        expect(gameModeService.isActive, isFalse);
      });

      test('should toggle multiple times correctly', () {
        for (var i = 0; i < 10; i++) {
          gameModeService.toggle();
          expect(gameModeService.isActive, i.isEven ? isTrue : isFalse);
        }
      });

      test('should emit state changes to stream on toggle', () async {
        final states = <bool>[];
        final subscription = gameModeService.isActiveStream.listen(states.add);

        gameModeService.toggle(); // true
        gameModeService.toggle(); // false
        gameModeService.toggle(); // true

        await Future<void>.delayed(const Duration(milliseconds: 50));
        subscription.cancel();

        expect(states, equals([true, false, true]));
      });
    });

    group('Notification Queuing - Requirement 6.1', () {
      test('should queue notifications when Game Mode is active', () {
        gameModeService.toggle(); // activate
        final item = createTestItem('test content');

        gameModeService.queueNotification(item);

        final queue = gameModeService.flushQueue();
        expect(queue.length, equals(1));
        expect(queue.first, equals(item));
      });

      test('should NOT queue notifications when Game Mode is inactive', () {
        expect(gameModeService.isActive, isFalse);
        final item = createTestItem('test content');

        gameModeService.queueNotification(item);

        final queue = gameModeService.flushQueue();
        expect(queue, isEmpty);
      });

      test('should queue multiple notifications in order (FIFO)', () {
        gameModeService.toggle(); // activate

        final item1 = createTestItem('first');
        final item2 = createTestItem('second');
        final item3 = createTestItem('third');

        gameModeService.queueNotification(item1);
        gameModeService.queueNotification(item2);
        gameModeService.queueNotification(item3);

        final queue = gameModeService.flushQueue();
        expect(queue.length, equals(3));
        expect(queue[0], equals(item1));
        expect(queue[1], equals(item2));
        expect(queue[2], equals(item3));
      });

      test('should limit queue size to maxQueueSize (50)', () {
        gameModeService.toggle(); // activate

        // Queue 60 items (exceeds max of 50)
        for (var i = 0; i < 60; i++) {
          gameModeService.queueNotification(createTestItem('item $i'));
        }

        final queue = gameModeService.flushQueue();
        expect(queue.length, equals(50)); // Should cap at 50

        // Should have removed oldest items (0-9)
        // And kept items 10-59
        expect(queue.first.content, equals('item 10'));
        expect(queue.last.content, equals('item 59'));
      });
    });

    group('Notification Callback - Requirement 6.3', () {
      test('should call notification callback when deactivating Game Mode', () {
        final notifiedItems = <ClipboardItem>[];
        gameModeService.setNotificationCallback(notifiedItems.add);

        gameModeService.toggle(); // activate
        final item1 = createTestItem('first');
        final item2 = createTestItem('second');
        gameModeService.queueNotification(item1);
        gameModeService.queueNotification(item2);

        expect(notifiedItems, isEmpty); // Not called yet

        gameModeService.toggle(); // deactivate - should flush queue

        expect(notifiedItems.length, equals(2));
        expect(notifiedItems[0], equals(item1));
        expect(notifiedItems[1], equals(item2));
      });

      test('should process notifications in sequence (FIFO)', () {
        final notifiedOrder = <String>[];
        gameModeService.setNotificationCallback((item) {
          notifiedOrder.add(item.content);
        });

        gameModeService.toggle(); // activate
        for (var i = 1; i <= 5; i++) {
          gameModeService.queueNotification(createTestItem('item $i'));
        }

        gameModeService.toggle(); // deactivate

        expect(
          notifiedOrder,
          equals(['item 1', 'item 2', 'item 3', 'item 4', 'item 5']),
        );
      });

      test('should clear queue after flushing on deactivate', () {
        final notifiedItems = <ClipboardItem>[];
        gameModeService.setNotificationCallback(notifiedItems.add);

        gameModeService.toggle(); // activate
        gameModeService.queueNotification(createTestItem('test'));
        gameModeService.toggle(); // deactivate - flushes

        expect(notifiedItems.length, equals(1));

        // Queue should be empty now
        final remainingQueue = gameModeService.flushQueue();
        expect(remainingQueue, isEmpty);
      });

      test('should handle null callback gracefully', () {
        gameModeService.setNotificationCallback(null);

        gameModeService.toggle(); // activate
        gameModeService.queueNotification(createTestItem('test'));

        // Should not throw when deactivating with null callback
        expect(() => gameModeService.toggle(), returnsNormally);
      });
    });

    group('Stream Reactivity', () {
      test('should broadcast state changes to all listeners', () async {
        final states1 = <bool>[];
        final states2 = <bool>[];

        final sub1 = gameModeService.isActiveStream.listen(states1.add);
        final sub2 = gameModeService.isActiveStream.listen(states2.add);

        gameModeService.toggle();
        gameModeService.toggle();

        await Future<void>.delayed(const Duration(milliseconds: 50));

        sub1.cancel();
        sub2.cancel();

        expect(states1, equals([true, false]));
        expect(states2, equals([true, false]));
      });

      test('should allow late listeners to subscribe', () async {
        gameModeService.toggle(); // activate before subscription

        final states = <bool>[];
        final subscription = gameModeService.isActiveStream.listen(states.add);

        gameModeService.toggle(); // deactivate after subscription

        await Future<void>.delayed(const Duration(milliseconds: 50));
        subscription.cancel();

        // Late subscriber only gets events after subscription
        expect(states, equals([false]));
      });
    });

    group('Dispose and Cleanup', () {
      test('should clear queue on dispose', () {
        gameModeService.toggle(); // activate
        gameModeService.queueNotification(createTestItem('test'));

        gameModeService.dispose();

        // Queue should be empty after dispose
        final queue = gameModeService.flushQueue();
        expect(queue, isEmpty);
      });

      test('should close stream controller on dispose', () async {
        gameModeService.dispose();

        // Stream should be closed, and listening should receive done immediately
        var receivedDone = false;
        gameModeService.isActiveStream.listen(
          (_) {},
          onDone: () => receivedDone = true,
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          receivedDone,
          isTrue,
          reason: 'Stream should be closed after dispose',
        );
      });

      test('should clear notification callback on dispose', () {
        var callbackCalled = false;
        gameModeService.setNotificationCallback((_) {
          callbackCalled = true;
        });

        gameModeService.toggle(); // activate
        gameModeService.queueNotification(createTestItem('test'));
        gameModeService.dispose();

        // Callback should be cleared, so this shouldn't call it
        expect(callbackCalled, isFalse);
      });
    });

    group('Performance Tests', () {
      test('should toggle in < 1ms', () {
        final stopwatch = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          gameModeService.toggle();
        }
        stopwatch.stop();

        // 100 toggles should be very fast
        expect(stopwatch.elapsedMilliseconds, lessThan(10));
      });

      test('should queue notification in < 1ms', () {
        gameModeService.toggle(); // activate

        final item = createTestItem('test content with reasonable length');
        final stopwatch = Stopwatch()..start();

        for (var i = 0; i < 100; i++) {
          gameModeService.queueNotification(item);
        }

        stopwatch.stop();

        expect(stopwatch.elapsedMilliseconds, lessThan(10));
      });

      test('should flush queue efficiently', () {
        gameModeService.toggle(); // activate

        // Queue 50 items (max size)
        for (var i = 0; i < 50; i++) {
          gameModeService.queueNotification(createTestItem('item $i'));
        }

        final stopwatch = Stopwatch()..start();
        final queue = gameModeService.flushQueue();
        stopwatch.stop();

        expect(queue.length, equals(50));
        expect(stopwatch.elapsedMilliseconds, lessThan(5));
      });
    });

    group('Requirement 6.4 - Toggle State Changes', () {
      test('should immediately switch between active and inactive states', () {
        expect(gameModeService.isActive, isFalse);

        gameModeService.toggle();
        expect(
          gameModeService.isActive,
          isTrue,
          reason: 'Should immediately activate',
        );

        gameModeService.toggle();
        expect(
          gameModeService.isActive,
          isFalse,
          reason: 'Should immediately deactivate',
        );
      });
    });
  });
}
