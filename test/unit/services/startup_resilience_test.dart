import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/main.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/crash_reporting_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Both service interfaces are wide and this only exercises three members of
/// them, so the doubles answer through noSuchMethod rather than stubbing
/// everything. Anything these tests do not name would throw, which is the
/// behaviour wanted: it would mean startup called something unexpected.
class _FakeAuth implements IAuthService {
  _FakeAuth({this.initError, this.user});

  final Object? initError;
  User? user;
  bool initialized = false;

  @override
  Future<void> initialize() async {
    initialized = true;
    final error = initError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }

  @override
  User? get currentUser => user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDevice implements IDeviceService {
  _FakeDevice({this.initError, this.registerError});

  final Object? initError;
  final Object? registerError;
  bool initialized = false;
  bool registerAttempted = false;

  @override
  Future<void> initialize() async {
    initialized = true;
    final error = initError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
  }

  @override
  Future<bool> registerCurrentDevice({String? fcmToken}) async {
    registerAttempted = true;
    final error = registerError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingReporter implements ICrashReportingService {
  final List<String> contexts = [];
  final List<Object> errors = [];

  @override
  Future<void> run(FutureOr<void> Function() app) async => app();

  @override
  Future<void> reportHandled(
    Object error,
    StackTrace stackTrace, {
    required String context,
  }) async {
    contexts.add(context);
    errors.add(error);
  }
}

/// A stand-in for a signed-in user. Only its non-nullness is read here.
User _someUser() => User(
  id: 'f0f0f0f0-0000-4000-8000-000000000000',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: DateTime.utc(2026).toIso8601String(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the happy path initializes both and registers the device', () async {
    final auth = _FakeAuth(user: _someUser());
    final device = _FakeDevice();
    final reporter = _RecordingReporter();

    await startAuthAndDevice(auth, device, reporter);

    expect(auth.initialized, isTrue);
    expect(device.initialized, isTrue);
    expect(device.registerAttempted, isTrue);
    expect(reporter.contexts, isEmpty);
  });

  // The crash this was written for: sign-in leaves no session, and
  // registerCurrentDevice throws a StateError that used to abandon the rest of
  // startup - the tray icon and hotkey included.
  test('no session after init skips registration instead of throwing', () async {
    final auth = _FakeAuth(); // currentUser stays null
    final device = _FakeDevice(
      registerError: StateError('User not authenticated.'),
    );
    final reporter = _RecordingReporter();

    await startAuthAndDevice(auth, device, reporter);

    expect(
      device.registerAttempted,
      isFalse,
      reason: 'it must not call a method it knows will throw',
    );
    expect(reporter.contexts, isEmpty);
  });

  test('an auth failure is reported and startup continues', () async {
    final auth = _FakeAuth(initError: AuthException('offline'));
    final device = _FakeDevice();
    final reporter = _RecordingReporter();

    await startAuthAndDevice(auth, device, reporter);

    expect(reporter.contexts, ['auth_and_device_init']);
    expect(reporter.errors.single, isA<AuthException>());
  });

  test('device init failing still lets auth finish, and is reported', () async {
    final auth = _FakeAuth(user: _someUser());
    final device = _FakeDevice(initError: StateError('no storage'));
    final reporter = _RecordingReporter();

    await startAuthAndDevice(auth, device, reporter);

    expect(auth.initialized, isTrue);
    expect(reporter.contexts, ['auth_and_device_init']);
  });

  // A session exists, so registration is attempted; it fails on its own terms
  // (offline, a unique-index conflict) and must not take startup with it.
  test('a registration failure is reported and swallowed', () async {
    final auth = _FakeAuth(user: _someUser());
    final device = _FakeDevice(registerError: Exception('conflict'));
    final reporter = _RecordingReporter();

    await startAuthAndDevice(auth, device, reporter);

    expect(device.registerAttempted, isTrue);
    expect(reporter.contexts, ['register_current_device']);
  });

  test('nothing it absorbs is ever rethrown', () async {
    final auth = _FakeAuth(initError: AuthException('offline'));
    final device = _FakeDevice(
      initError: StateError('no storage'),
      registerError: Exception('conflict'),
    );

    await expectLater(
      startAuthAndDevice(auth, device, _RecordingReporter()),
      completes,
    );
  });
}
