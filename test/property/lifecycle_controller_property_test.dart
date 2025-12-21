import 'package:ghostcopy/services/impl/lifecycle_controller.dart';
import 'package:ghostcopy/services/lifecycle_controller.dart';
import 'package:glados/glados.dart';

/// Mock pausable resource for testing
class _MockPausable implements Pausable {
  bool isPaused = false;
  int pauseCount = 0;
  int resumeCount = 0;

  @override
  void pause() {
    isPaused = true;
    pauseCount++;
  }

  @override
  void resume() {
    isPaused = false;
    resumeCount++;
  }
}

void main() {
  group('LifecycleController Property Tests', () {
    /**
     * Feature: ghostcopy
     * Property 2: Sleep Mode Resource Pausing
     *
     * GIVEN a LifecycleController with N pausable resources
     * WHEN enterSleepMode() is called
     * THEN all N resources SHALL be paused
     * AND isSleeping SHALL be true
     */
    Glados(any.positiveInt.map((n) => (n % 99) + 1)).test(
      '**Feature: ghostcopy, Property 2: Sleep Mode Resource Pausing**',
      (resourceCount) {
        // GIVEN: Create controller with N pausable resources
        final controller = LifecycleController();
        final resources = List.generate(
          resourceCount,
          (_) => _MockPausable(),
        );

        for (final resource in resources) {
          controller.addPausable(resource);
        }

        // WHEN: Enter sleep mode
        controller.enterSleepMode();

        // THEN: All resources are paused
        for (final resource in resources) {
          expect(
            resource.isPaused,
            isTrue,
            reason: 'Resource should be paused after enterSleepMode()',
          );
          expect(
            resource.pauseCount,
            equals(1),
            reason: 'Resource should be paused exactly once',
          );
        }

        // AND: Controller is in sleeping state
        expect(
          controller.isSleeping,
          isTrue,
          reason: 'Controller should report isSleeping = true',
        );

        // Cleanup
        controller.dispose();
      },
    );

    /**
     * Feature: ghostcopy
     * Property 3: Sleep Mode Round-Trip
     *
     * GIVEN a LifecycleController with N pausable resources
     * WHEN enterSleepMode() is called THEN exitSleepMode() is called
     * THEN all N resources SHALL be resumed
     * AND isSleeping SHALL be false
     * AND each resource SHALL have been paused exactly once
     * AND each resource SHALL have been resumed exactly once
     */
    Glados(any.positiveInt.map((n) => (n % 99) + 1)).test(
      '**Feature: ghostcopy, Property 3: Sleep Mode Round-Trip**',
      (resourceCount) {
        // GIVEN: Create controller with N pausable resources
        final controller = LifecycleController();
        final resources = List.generate(
          resourceCount,
          (_) => _MockPausable(),
        );

        for (final resource in resources) {
          controller.addPausable(resource);
        }

        // WHEN: Enter sleep mode then exit sleep mode
        controller
          ..enterSleepMode()
          ..exitSleepMode();

        // THEN: All resources are resumed
        for (final resource in resources) {
          expect(
            resource.isPaused,
            isFalse,
            reason: 'Resource should be resumed after exitSleepMode()',
          );
          expect(
            resource.pauseCount,
            equals(1),
            reason: 'Resource should be paused exactly once',
          );
          expect(
            resource.resumeCount,
            equals(1),
            reason: 'Resource should be resumed exactly once',
          );
        }

        // AND: Controller is no longer sleeping
        expect(
          controller.isSleeping,
          isFalse,
          reason: 'Controller should report isSleeping = false',
        );

        // Cleanup
        controller.dispose();
      },
    );

    /**
     * Feature: ghostcopy
     * Property 4: Late-Added Resources
     *
     * GIVEN a LifecycleController in sleep mode
     * WHEN a new pausable resource is added
     * THEN the new resource SHALL be immediately paused
     */
    test('Property 4: Late-Added Resources', () {
      final controller = LifecycleController()
        ..enterSleepMode();

      // Enter sleep mode first
      expect(controller.isSleeping, isTrue);

      // Add a new resource while sleeping
      final lateResource = _MockPausable();
      controller.addPausable(lateResource);

      // The newly added resource should be immediately paused
      expect(
        lateResource.isPaused,
        isTrue,
        reason: 'Late-added resource should be immediately paused',
      );
      expect(
        lateResource.pauseCount,
        equals(1),
        reason: 'Late-added resource should be paused exactly once',
      );

      controller.dispose();
    });

    /**
     * Feature: ghostcopy
     * Property 5: Idempotent Sleep Mode
     *
     * GIVEN a LifecycleController in sleep mode
     * WHEN enterSleepMode() is called again
     * THEN resources SHALL NOT be paused again
     * AND pauseCount SHALL remain 1
     */
    test('Property 5: Idempotent Sleep Mode', () {
      final controller = LifecycleController();
      final resource = _MockPausable();

      // Enter sleep mode twice
      controller
        ..addPausable(resource)
        ..enterSleepMode()
        ..enterSleepMode();

      // Resource should only be paused once
      expect(
        resource.pauseCount,
        equals(1),
        reason: 'Resource should only be paused once despite multiple calls',
      );
      expect(controller.isSleeping, isTrue);

      controller.dispose();
    });

    /**
     * Feature: ghostcopy
     * Property 6: Idempotent Wake Mode
     *
     * GIVEN a LifecycleController NOT in sleep mode
     * WHEN exitSleepMode() is called
     * THEN resources SHALL NOT be resumed
     * AND resumeCount SHALL remain 0
     */
    test('Property 6: Idempotent Wake Mode', () {
      final controller = LifecycleController();
      final resource = _MockPausable();
      controller
        ..addPausable(resource)
        // Try to exit sleep mode without entering it
        ..exitSleepMode();

      // Resource should not be resumed
      expect(
        resource.resumeCount,
        equals(0),
        reason: 'Resource should not be resumed if not sleeping',
      );
      expect(controller.isSleeping, isFalse);

      controller.dispose();
    });
  });
}
