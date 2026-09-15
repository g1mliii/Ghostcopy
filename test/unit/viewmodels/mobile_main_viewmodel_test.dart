import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/viewmodels/mobile_main_viewmodel.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthService extends Mock implements IAuthService {}

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

class _MockDeviceService extends Mock implements IDeviceService {}

class _MockSecurityService extends Mock implements ISecurityService {}

class _MockSettingsService extends Mock implements ISettingsService {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      ClipboardItem(
        id: 'fallback',
        userId: 'fallback-user',
        content: 'fallback',
        deviceType: 'windows',
        createdAt: DateTime(2026),
      ),
    );
  });

  late _MockAuthService authService;
  late _MockClipboardRepository clipboardRepository;
  late _MockDeviceService deviceService;
  late _MockSecurityService securityService;
  late _MockSettingsService settingsService;
  late MobileMainViewModel viewModel;

  setUp(() {
    authService = _MockAuthService();
    clipboardRepository = _MockClipboardRepository();
    deviceService = _MockDeviceService();
    securityService = _MockSecurityService();
    settingsService = _MockSettingsService();

    when(
      () => clipboardRepository.getHistory(),
    ).thenAnswer((_) async => <ClipboardItem>[]);
    when(
      () => settingsService.getClipboardAutoClearSeconds(),
    ).thenAnswer((_) async => 0);

    viewModel = MobileMainViewModel(
      authService: authService,
      clipboardRepository: clipboardRepository,
      deviceService: deviceService,
      securityService: securityService,
    );
  });

  tearDown(() {
    viewModel.dispose();
  });

  test(
    'account switch cancels the old stream and receives new account clips',
    () async {
      final oldStream = StreamController<List<ClipboardItem>>();
      final newStream = StreamController<List<ClipboardItem>>();
      when(
        () => clipboardRepository.watchHistory(),
      ).thenAnswer((_) => oldStream.stream);
      viewModel.subscribeToRealtimeUpdates();
      expect(oldStream.hasListener, isTrue);
      when(
        () => clipboardRepository.watchHistory(),
      ).thenAnswer((_) => newStream.stream);
      when(
        () => deviceService.getUserDevices(forceRefresh: true),
      ).thenAnswer((_) async => []);
      await viewModel.reloadForCurrentUser();
      expect(oldStream.hasListener, isFalse);
      expect(newStream.hasListener, isTrue);
      newStream.add([
        ClipboardItem(
          id: 'new',
          userId: 'new-user',
          content: 'new clip',
          deviceType: 'android',
          targetDeviceTypes: ['not-this-platform'],
          createdAt: DateTime(2026),
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.historyItems.single.id, 'new');
      await oldStream.close();
      await newStream.close();
    },
  );

  test(
    'an old account history request cannot overwrite the new account',
    () async {
      final oldRequest = Completer<List<ClipboardItem>>();
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) => oldRequest.future);
      final loadingOld = viewModel.loadHistory();
      when(
        () => clipboardRepository.watchHistory(),
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => deviceService.getUserDevices(forceRefresh: true),
      ).thenAnswer((_) async => []);
      when(() => clipboardRepository.getHistory()).thenAnswer((_) async => []);
      await viewModel.reloadForCurrentUser();
      oldRequest.complete([
        ClipboardItem(
          id: 'old',
          userId: 'old-user',
          content: 'private',
          deviceType: 'android',
          createdAt: DateTime(2026),
        ),
      ]);
      await loadingOld;
      expect(viewModel.historyItems, isEmpty);
    },
  );

  test('checkSensitiveData uses async security detection', () async {
    when(
      () => securityService.detectSensitiveDataAsync('api_key=secret'),
    ).thenAnswer(
      (_) async => const DetectionResult(
        isSensitive: true,
        type: SensitiveDataType.apiKey,
      ),
    );

    final result = await viewModel.checkSensitiveData('api_key=secret');

    expect(result, isTrue);
    verify(
      () => securityService.detectSensitiveDataAsync('api_key=secret'),
    ).called(1);
  });

  test('handleSend sends text item and clears send state on success', () async {
    when(() => authService.currentUserId).thenReturn('user-123');
    when(() => clipboardRepository.insert(any())).thenAnswer(
      (_) async => ClipboardItem(
        id: '1',
        userId: 'user-123',
        content: 'hello mobile',
        deviceType: 'windows',
        createdAt: DateTime(2026),
      ),
    );

    await viewModel.handleSend('hello mobile');

    final inserted =
        verify(() => clipboardRepository.insert(captureAny())).captured.single
            as ClipboardItem;

    expect(inserted.userId, 'user-123');
    expect(inserted.content, 'hello mobile');
    expect(inserted.targetDeviceTypes, isNull);
    expect(viewModel.isSending, isFalse);
    expect(viewModel.sendErrorMessage, isNull);
    expect(viewModel.clipboardContent, isNull);
  });

  test('handleSend sets validation error for empty text input', () async {
    await viewModel.handleSend('   ');

    verifyNever(() => clipboardRepository.insert(any()));
    expect(viewModel.sendErrorMessage, 'Please paste or type content to send');
    expect(viewModel.isSending, isFalse);
  });

  group('history error lifecycle', () {
    ClipboardItem item(String id) => ClipboardItem(
      id: id,
      userId: 'u1',
      content: 'clip $id',
      deviceType: 'windows',
      createdAt: DateTime(2026),
    );

    test('a failed load reports an error when nothing is on screen', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenThrow(Exception('network down'));

      await viewModel.loadHistory();

      expect(viewModel.historyError, isNotNull);
      expect(viewModel.historyLoading, isFalse);
    });

    test('a successful load clears a previous error', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenThrow(Exception('network down'));
      await viewModel.loadHistory();
      expect(viewModel.historyError, isNotNull);

      // Pull to refresh, and this time the fetch works.
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => [item('1')]);
      await viewModel.loadHistory();

      // The regression: historyError was only ever cleared on sign-out, and
      // the UI returns the error pane before it looks at the items - so the
      // list stayed hidden and pull-to-refresh looked like it did nothing.
      expect(viewModel.historyError, isNull);
      expect(viewModel.filteredHistoryItems, hasLength(1));
    });

    test('a failed refresh keeps the clips already loaded', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => [item('1'), item('2')]);
      await viewModel.loadHistory();

      when(
        () => clipboardRepository.getHistory(),
      ).thenThrow(Exception('network down'));
      await viewModel.loadHistory();

      // Losing the connection must not blank a list the user can still read.
      expect(viewModel.filteredHistoryItems, hasLength(2));
      expect(viewModel.historyError, isNull);
    });

    test('an active search survives a reload', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => [item('1'), item('2')]);
      await viewModel.loadHistory();
      viewModel.filterHistory('clip 2');
      expect(viewModel.filteredHistoryItems, hasLength(1));

      await viewModel.loadHistory();

      // loadHistory used to assign the unfiltered list straight to
      // _filteredHistoryItems, so a background refresh silently dropped the
      // user's search.
      expect(viewModel.filteredHistoryItems, hasLength(1));
      expect(viewModel.filteredHistoryItems.single.id, '2');
    });
  });

  group('device type targeting', () {
    Device device(String id, String type, String name) => Device(
      id: id,
      userId: 'u1',
      deviceType: type,
      deviceName: name,
      lastActive: DateTime(2026),
      createdAt: DateTime(2026),
    );

    test('two devices of one type collapse to a single chip', () async {
      when(
        () => deviceService.getUserDevices(
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer(
        (_) async => [
          device('1', 'windows', 'Work PC'),
          device('2', 'windows', 'Home PC'),
          device('3', 'android', 'Pixel'),
        ],
      );
      await viewModel.loadDevices();

      final targets = viewModel.deviceTypeTargets;

      // target_device_type is an enum array - the backend cannot address an
      // individual machine, so one chip per device was a promise it could not
      // keep. Three devices, two types, two chips.
      expect(targets, hasLength(2));
      expect(
        targets.map((t) => t.deviceType),
        containsAll(['windows', 'android']),
      );
    });

    test('a chip is labelled by platform, never by device name', () async {
      when(
        () => deviceService.getUserDevices(
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer(
        (_) async => [
          device('1', 'windows', 'Work PC'),
          device('2', 'windows', 'Home PC'),
        ],
      );
      await viewModel.loadDevices();

      final windows = viewModel.deviceTypeTargets.single;

      // A chip selects a device_type_enum, so the platform is what it does.
      // Naming either machine would also be a lie - the clip reaches both.
      expect(windows.label, 'Windows');
      expect(
        windows.deviceNames,
        allOf(contains('Work PC'), contains('Home PC')),
      );
    });

    test('a lone device of its type is still labelled by platform', () async {
      when(
        () => deviceService.getUserDevices(
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer((_) async => [device('1', 'windows', 'Work PC')]);
      await viewModel.loadDevices();

      // Using the device name here would be accurate but inconsistent: the
      // same chip would read "Work PC" today and "Windows" after adding a
      // second PC. The name stays available via deviceNames.
      expect(viewModel.deviceTypeTargets.single.label, 'Windows');
      expect(viewModel.deviceTypeTargets.single.deviceNames, 'Work PC');
    });

    test('platformLabel spells product names properly', () {
      // Capitalising the first letter gave "Macos" and "Ios".
      expect(DeviceTypeTarget.platformLabel('macos'), 'macOS');
      expect(DeviceTypeTarget.platformLabel('ios'), 'iOS');
      expect(DeviceTypeTarget.platformLabel('windows'), 'Windows');
      expect(DeviceTypeTarget.platformLabel('android'), 'Android');
    });
  });

  group('delete', () {
    ClipboardItem item(String id) => ClipboardItem(
      id: id,
      userId: 'u1',
      content: 'clip $id',
      deviceType: 'windows',
      createdAt: DateTime(2026),
    );

    test('removes the clip from the list on success', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => [item('1'), item('2')]);
      await viewModel.loadHistory();
      when(() => clipboardRepository.delete('1')).thenAnswer((_) async {});

      final ok = await viewModel.handleHistoryItemDelete(item('1'));

      expect(ok, isTrue);
      expect(viewModel.filteredHistoryItems.map((i) => i.id), ['2']);
    });

    test(
      'restores the clip at its original index when the delete fails',
      () async {
        when(
          () => clipboardRepository.getHistory(),
        ).thenAnswer((_) async => [item('1'), item('2'), item('3')]);
        await viewModel.loadHistory();
        when(
          () => clipboardRepository.delete('2'),
        ).thenThrow(Exception('offline'));

        final ok = await viewModel.handleHistoryItemDelete(item('2'));

        // The row is removed optimistically so it does not spring back mid-swipe.
        // If the server never deleted it, leaving the list short would claim a
        // deletion that did not happen - and the clip is still on every device.
        expect(ok, isFalse);
        expect(viewModel.filteredHistoryItems.map((i) => i.id), [
          '1',
          '2',
          '3',
        ]);
      },
    );
  });
}
