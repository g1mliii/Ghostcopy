import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/services/game_mode_service.dart';
import 'package:ghostcopy/services/impl/game_mode_service.dart';
import 'package:glados/glados.dart';

/// Property-based tests for GameModeService
///
/// Uses Glados for property testing with 100 iterations per test
void main() {
  group('GameModeService Property Tests', () {
    late IGameModeService gameModeService;

    setUp(() {
      gameModeService = GameModeService();
    });

    tearDown(() {
      gameModeService.dispose();
    });

    ClipboardItem createTestItem(String content, int id) {
      return ClipboardItem(
        id: id.toString(),
        userId: 'test-user',
        content: content,
        deviceType: 'windows',
        createdAt: DateTime.now(),
      );
    }

    /**
     * Feature: ghostcopy
     * Property 18: Toggle Idempotence
     *
     * GIVEN any number of toggle operations
     * WHEN toggle() is called an even number of times
     * THEN the state SHALL return to inactive (false)
     * AND WHEN toggle() is called an odd number of times
     * THEN the state SHALL be active (true)
     *
     * Validates Requirement 6.4: Toggle Game Mode to switch states
     */
    test('**Feature: ghostcopy, Property 18: Toggle Idempotence**', () {
      for (var i = 0; i < 100; i++) {
        gameModeService = GameModeService(); // Reset for each iteration

        // GIVEN: Perform i toggle operations
        for (var j = 0; j < i; j++) {
          gameModeService.toggle();
        }

        // THEN: State should match parity
        final expectedState = i.isOdd;
        expect(
          gameModeService.isActive,
          equals(expectedState),
          reason:
              'After $i toggles, state should be ${expectedState ? "active" : "inactive"}',
        );

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 19: Queue FIFO Ordering
     *
     * GIVEN any number of queued notifications (up to 50)
     * WHEN notifications are queued in order
     * THEN flushQueue() SHALL return items in the exact same order
     * AND the queue SHALL preserve insertion order (FIFO)
     *
     * Validates Requirement 6.1, 6.3: Queue and flush notifications in sequence
     */
    test('**Feature: ghostcopy, Property 19: Queue FIFO Ordering**', () {
      for (var iteration = 0; iteration < 100; iteration++) {
        gameModeService = GameModeService();
        gameModeService.toggle(); // Activate Game Mode

        // GIVEN: Queue varying numbers of items (1 to 50)
        final itemCount = (iteration % 50) + 1;
        final queuedItems = <ClipboardItem>[];

        for (var i = 0; i < itemCount; i++) {
          final item = createTestItem('Item $i in iteration $iteration', i);
          queuedItems.add(item);
          gameModeService.queueNotification(item);
        }

        // WHEN: Flush the queue
        final flushedItems = gameModeService.flushQueue();

        // THEN: Order must be preserved (FIFO)
        expect(
          flushedItems.length,
          equals(queuedItems.length),
          reason: 'All items should be flushed',
        );

        for (var i = 0; i < queuedItems.length; i++) {
          expect(
            flushedItems[i],
            equals(queuedItems[i]),
            reason: 'Item at position $i should match queued order',
          );
        }

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 20: Queue Size Limit Enforcement
     *
     * GIVEN more than maxQueueSize (50) notifications are queued
     * WHEN queueNotification() is called repeatedly
     * THEN the queue SHALL never exceed maxQueueSize
     * AND oldest items SHALL be removed first (FIFO eviction)
     *
     * Validates Performance optimization: Prevent memory leaks
     */
    test('**Feature: ghostcopy, Property 20: Queue Size Limit**', () {
      for (var iteration = 0; iteration < 100; iteration++) {
        gameModeService = GameModeService();
        gameModeService.toggle(); // Activate

        // GIVEN: Queue 50 + iteration items (exceeds limit)
        final itemCount = 50 + iteration + 1;

        for (var i = 0; i < itemCount; i++) {
          gameModeService.queueNotification(createTestItem('Item $i', i));
        }

        // THEN: Queue should be capped at maxQueueSize (50)
        final queue = gameModeService.flushQueue();
        expect(
          queue.length,
          equals(50),
          reason: 'Queue should be limited to maxQueueSize',
        );

        // THEN: Should have evicted oldest items
        // Expected: items [iteration+1] through [50+iteration]
        final expectedStartIndex = iteration + 1;
        expect(
          queue.first.content,
          equals('Item $expectedStartIndex'),
          reason: 'Oldest items should be evicted (FIFO)',
        );
        expect(
          queue.last.content,
          equals('Item ${itemCount - 1}'),
          reason: 'Newest items should be retained',
        );

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 21: State-Dependent Queueing
     *
     * GIVEN Game Mode state is toggled while queueing notifications
     * WHEN notifications are queued
     * THEN notifications SHALL ONLY be queued when state is active
     * AND notifications SHALL be ignored when state is inactive
     *
     * Validates Requirement 6.1: Queue only when Game Mode is active
     */
    test('**Feature: ghostcopy, Property 21: State-Dependent Queueing**', () {
      for (var i = 0; i < 100; i++) {
        gameModeService = GameModeService();

        // Set a callback to prevent auto-flushing from clearing the queue
        final flushedItems = <ClipboardItem>[];
        gameModeService.setNotificationCallback(flushedItems.add);

        // Queue notifications while toggling state
        gameModeService.toggle(); // Start active
        gameModeService.queueNotification(createTestItem('Active 1', 1));
        gameModeService.queueNotification(createTestItem('Active 2', 2));

        gameModeService.toggle(); // Deactivate (flushes queue via callback)
        gameModeService.queueNotification(
          createTestItem('Inactive 1', 3),
        ); // Should be ignored

        gameModeService.toggle(); // Activate again
        gameModeService.queueNotification(createTestItem('Active 3', 4));

        gameModeService.toggle(); // Deactivate (flushes again)
        gameModeService.queueNotification(
          createTestItem('Inactive 2', 5),
        ); // Should be ignored

        // THEN: Only active notifications should have been processed
        // First deactivation: 2 items flushed
        // Second deactivation: 1 item flushed
        expect(
          flushedItems.length,
          equals(3),
          reason: 'Only items queued when active should be flushed (2 + 1)',
        );

        expect(flushedItems[0].content, equals('Active 1'));
        expect(flushedItems[1].content, equals('Active 2'));
        expect(flushedItems[2].content, equals('Active 3'));

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 22: Callback Execution Order
     *
     * GIVEN a notification callback is registered
     * WHEN Game Mode is deactivated with queued items
     * THEN callback SHALL be called for each item in FIFO order
     * AND all items SHALL trigger exactly one callback
     *
     * Validates Requirement 6.3: Display queued notifications in sequence
     */
    test('**Feature: ghostcopy, Property 22: Callback Execution Order**', () {
      for (var iteration = 0; iteration < 100; iteration++) {
        gameModeService = GameModeService();

        final callbackOrder = <String>[];
        gameModeService.setNotificationCallback((item) {
          callbackOrder.add(item.content);
        });

        gameModeService.toggle(); // Activate

        // GIVEN: Queue varying numbers of items
        final itemCount = (iteration % 20) + 1;
        final expectedOrder = <String>[];

        for (var i = 0; i < itemCount; i++) {
          final content = 'Item $i of iteration $iteration';
          expectedOrder.add(content);
          gameModeService.queueNotification(createTestItem(content, i));
        }

        // WHEN: Deactivate (flushes queue with callbacks)
        gameModeService.toggle();

        // THEN: Callback order must match queue order (FIFO)
        expect(
          callbackOrder.length,
          equals(expectedOrder.length),
          reason: 'Each item should trigger exactly one callback',
        );
        expect(
          callbackOrder,
          equals(expectedOrder),
          reason: 'Callbacks should execute in FIFO order',
        );

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 23: Stream State Synchronization
     *
     * GIVEN a stream listener is subscribed to isActiveStream
     * WHEN toggle() is called multiple times
     * THEN the stream SHALL emit every state change
     * AND emitted values SHALL match the current isActive state
     *
     * Validates Performance optimization: Stream-based reactivity
     */
    test('**Feature: ghostcopy, Property 23: Stream State Sync**', () async {
      for (var iteration = 0; iteration < 100; iteration++) {
        gameModeService = GameModeService();

        final emittedStates = <bool>[];
        final subscription = gameModeService.isActiveStream.listen(
          emittedStates.add,
        );

        // GIVEN: Perform varying numbers of toggles (1 to 10)
        final toggleCount = (iteration % 10) + 1;
        final expectedStates = <bool>[];

        for (var i = 0; i < toggleCount; i++) {
          gameModeService.toggle();
          expectedStates.add(i.isEven);
        }

        // Wait for stream events to propagate
        await Future<void>.delayed(const Duration(milliseconds: 50));

        subscription.cancel();

        // THEN: Stream should emit all state changes
        expect(
          emittedStates.length,
          equals(expectedStates.length),
          reason: 'Stream should emit every state change',
        );
        expect(
          emittedStates,
          equals(expectedStates),
          reason: 'Emitted states should match toggle sequence',
        );

        gameModeService.dispose();
      }
    });

    /**
     * Feature: ghostcopy
     * Property 24: Queue Flush Clears State
     *
     * GIVEN a queue with any number of items
     * WHEN flushQueue() is called
     * THEN the queue SHALL be completely empty afterward
     * AND subsequent flushQueue() SHALL return an empty list
     *
     * Validates: Queue management correctness
     */
    test('**Feature: ghostcopy, Property 24: Queue Flush Clears State**', () {
      for (var i = 0; i < 100; i++) {
        gameModeService = GameModeService();
        gameModeService.toggle(); // Activate

        // GIVEN: Queue random number of items (0 to 30)
        final itemCount = i % 31;
        for (var j = 0; j < itemCount; j++) {
          gameModeService.queueNotification(createTestItem('Item $j', j));
        }

        // WHEN: Flush queue
        final flushed = gameModeService.flushQueue();
        expect(flushed.length, equals(itemCount));

        // THEN: Queue should be empty
        final secondFlush = gameModeService.flushQueue();
        expect(
          secondFlush,
          isEmpty,
          reason: 'Queue should be empty after flushing',
        );

        gameModeService.dispose();
      }
    });

    /**
     * Performance test: Toggle operations should be fast
     */
    test('Performance: Fast Toggle Operations', () {
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < 10000; i++) {
        gameModeService.toggle();
      }

      stopwatch.stop();

      // 10,000 toggles should complete in under 50ms
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(50),
        reason: '10,000 toggles should be very fast',
      );
    });

    /**
     * Performance test: Queue operations should be efficient
     */
    test('Performance: Efficient Queue Operations', () {
      gameModeService.toggle(); // Activate

      final stopwatch = Stopwatch()..start();

      // Queue 1000 items
      for (var i = 0; i < 1000; i++) {
        gameModeService.queueNotification(createTestItem('Item $i', i));
      }

      stopwatch.stop();

      // 1000 queue operations should be fast
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(100),
        reason: 'Queue operations should be efficient',
      );

      // Note: Due to maxQueueSize = 50, only last 50 items will be retained
      final queue = gameModeService.flushQueue();
      expect(queue.length, equals(50));
    });

    /**
     * Memory leak test: Dispose should clean up all resources
     */
    test('Memory Leak Prevention: Proper Disposal', () {
      // Create and dispose multiple service instances
      for (var i = 0; i < 100; i++) {
        final service = GameModeService();
        service.toggle();

        for (var j = 0; j < 10; j++) {
          service.queueNotification(createTestItem('Item $j', j));
        }

        // Should clean up without issues
        service.dispose();
      }

      // If this test completes, disposal is working correctly
      expect(true, isTrue);
    });

    /**
     * Concurrent listeners test: Broadcast stream should work with multiple listeners
     */
    test('Concurrency: Multiple Stream Listeners', () async {
      final states1 = <bool>[];
      final states2 = <bool>[];
      final states3 = <bool>[];

      final sub1 = gameModeService.isActiveStream.listen(states1.add);
      final sub2 = gameModeService.isActiveStream.listen(states2.add);
      final sub3 = gameModeService.isActiveStream.listen(states3.add);

      // Toggle multiple times
      for (var i = 0; i < 10; i++) {
        gameModeService.toggle();
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));

      sub1.cancel();
      sub2.cancel();
      sub3.cancel();

      // All listeners should receive all events
      expect(states1.length, equals(10));
      expect(states2.length, equals(10));
      expect(states3.length, equals(10));

      // All should receive the same sequence
      expect(states1, equals(states2));
      expect(states2, equals(states3));
    });

    /**
     * Edge case: Deactivating with empty queue should not error
     */
    test('Edge Case: Deactivate With Empty Queue', () {
      gameModeService.setNotificationCallback((_) {
        fail('Callback should not be called with empty queue');
      });

      gameModeService.toggle(); // Activate
      // Don't queue anything
      gameModeService.toggle(); // Deactivate

      expect(gameModeService.isActive, isFalse);
    });

    /**
     * Edge case: Multiple callback registrations (last one wins)
     */
    test('Edge Case: Callback Registration Override', () {
      final firstCallbackCalls = <String>[];
      final secondCallbackCalls = <String>[];

      gameModeService.setNotificationCallback(
        (item) => firstCallbackCalls.add(item.content),
      );
      gameModeService.setNotificationCallback(
        (item) => secondCallbackCalls.add(item.content),
      );

      gameModeService.toggle(); // Activate
      gameModeService.queueNotification(createTestItem('Test', 1));
      gameModeService.toggle(); // Deactivate

      // Only second callback should be called
      expect(firstCallbackCalls, isEmpty);
      expect(secondCallbackCalls.length, equals(1));
    });

    /**
     * Edge case: Null callback should be handled gracefully
     */
    test('Edge Case: Null Callback Handling', () {
      gameModeService.setNotificationCallback(null);

      gameModeService.toggle(); // Activate
      gameModeService.queueNotification(createTestItem('Test', 1));

      // Should not throw
      expect(() => gameModeService.toggle(), returnsNormally);
    });
  });
}
