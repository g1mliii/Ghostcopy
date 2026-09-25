import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/viewmodels/mobile_main_viewmodel.dart';
import 'package:ghostcopy/utils/platform_label.dart';
import 'package:mocktail/mocktail.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

class _MockAuthService extends Mock implements IAuthService {}

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

class _MockDeviceService extends Mock implements IDeviceService {}

class _MockSecurityService extends Mock implements ISecurityService {}

class _MockSettingsService extends Mock implements ISettingsService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  for (final filename in ['original.png', 'original.heic']) {
    test('gallery selection preserves $filename without compression', () async {
      final bytes = filename.endsWith('.png')
          ? Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4])
          : Uint8List.fromList([
              0,
              0,
              0,
              24,
              102,
              116,
              121,
              112,
              104,
              101,
              105,
              99,
            ]);
      const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'image');
            final arguments = call.arguments as Map<Object?, Object?>;
            expect(arguments['compressionQuality'], 0);
            expect(arguments['allowMultipleSelection'], isFalse);
            return [
              {'name': filename, 'size': bytes.length, 'bytes': bytes},
            ];
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      String? error;
      await viewModel.handleImageUpload(onError: (message) => error = message);
      expect(error, isNull);
      expect(viewModel.isUploadingImage, isFalse);
      if (filename.endsWith('.png')) {
        expect(viewModel.clipboardContent?.imageBytes, orderedEquals(bytes));
        expect(viewModel.clipboardContent?.mimeType, 'image/png');
      } else {
        expect(viewModel.clipboardContent?.fileBytes, orderedEquals(bytes));
        expect(viewModel.clipboardContent?.filename, filename);
        expect(viewModel.clipboardContent?.mimeType, 'image/heic');
      }
      // Picking stages the original; sending remains an explicit action.
      verifyZeroInteractions(clipboardRepository);
    });
  }

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

    test('the first load shows loading while nothing is on screen', () async {
      final request = Completer<List<ClipboardItem>>();
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) => request.future);

      final loading = viewModel.loadHistory();
      expect(viewModel.historyLoading, isTrue);

      request.complete([item('1')]);
      await loading;
      expect(viewModel.historyLoading, isFalse);
    });

    test('reopening the app refreshes the clips without hiding them', () async {
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => [item('1'), item('2')]);
      await viewModel.loadHistory();

      // Back from the background, the reload is in flight.
      final request = Completer<List<ClipboardItem>>();
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) => request.future);
      viewModel.onAppResumed();
      await Future<void>.delayed(Duration.zero);

      // The regression: loading was flagged on every resume, and the screen
      // shows the spinner instead of the list whenever it is - so the clips
      // flashed out and back in each time the app was reopened.
      expect(viewModel.historyLoading, isFalse);
      expect(viewModel.filteredHistoryItems, hasLength(2));

      request.complete([item('3'), item('1'), item('2')]);
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.historyLoading, isFalse);
      expect(viewModel.filteredHistoryItems.map((i) => i.id), ['3', '1', '2']);
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
      expect(platformLabel('macos'), 'macOS');
      expect(platformLabel('ios'), 'iOS');
      expect(platformLabel('windows'), 'Windows');
      expect(platformLabel('android'), 'Android');
      // linux is in device_type_enum and in validDeviceTypes, so a chip can be
      // built for it; the assertions above happened to skip the one platform a
      // hand-written list had previously omitted.
      expect(platformLabel('linux'), 'Linux');
    });

    test('platformLabel does not care about case', () {
      // device_type is a Postgres enum, so real rows are always lowercase.
      // This is the safety net that let DeviceTypeTarget's own copy of this
      // mapping - which switched on the raw string - be deleted rather than
      // kept for the one case it handled differently.
      expect(platformLabel('MacOS'), 'macOS');
      expect(platformLabel('IOS'), 'iOS');
    });
  });

  group('share sheet', () {
    test('a shared file with no session reports it instead of throwing', () async {
      // getInitialMedia() fires on a cold launch and can beat the anonymous
      // sign-in that normally guarantees a session. This used to be
      // `currentUserId!`, and the resulting TypeError is an Error, not an
      // Exception - so it escaped the per-item catch, took the rest of the
      // batch and the history reload with it, and left onError uncalled, which
      // is the one thing that would have told the user anything.
      when(() => authService.currentUserId).thenReturn(null);
      final errors = <String>[];

      await viewModel.handleSharedFiles([
        SharedMediaFile(path: '/tmp/a.pdf', type: SharedMediaType.file),
        SharedMediaFile(path: '/tmp/b.pdf', type: SharedMediaType.file),
      ], onError: errors.add);

      expect(
        errors.length,
        2,
        reason: 'both items report; the first must not abandon the second',
      );
      // The history reload at the end of the batch is the other thing the
      // escaping Error used to skip, and the one the user would actually
      // notice: the app opens, the share is gone, and the list never refreshes.
      await Future<void>.delayed(Duration.zero);
      verify(() => clipboardRepository.getHistory()).called(greaterThan(0));
    });
  });

  group('share progress', () {
    // Sharing from another app opens GhostCopy and sends from there; the
    // overlay is the only thing telling the user what is happening.
    late List<ShareProgressStage?> stages;
    late Future<ClipboardItem> Function(Invocation) insert;

    setUp(() {
      stages = [];
      viewModel.addListener(() => stages.add(viewModel.shareProgress?.stage));
      when(() => authService.currentUserId).thenReturn('u1');
      insert = (inv) async => inv.positionalArguments.first as ClipboardItem;
      when(
        () => clipboardRepository.insert(any()),
      ).thenAnswer((inv) => insert(inv));
    });

    SharedMediaFile text(String value) =>
        SharedMediaFile(path: value, type: SharedMediaType.text);

    test('shows sending, then sent, then goes by itself', () async {
      final sharing = viewModel.handleSharedFiles(
        [text('hello')],
        targetDeviceTypes: {'macos'},
      );
      expect(viewModel.shareProgress?.stage, ShareProgressStage.sending);
      expect(viewModel.shareProgress?.destination, 'macOS');
      expect(viewModel.shareProgress?.summary, 'Text');

      await sharing;
      expect(viewModel.shareProgress?.stage, ShareProgressStage.sent);

      await Future<void>.delayed(
        MobileMainViewModel.shareSentLinger + const Duration(milliseconds: 50),
      );
      expect(viewModel.shareProgress, isNull);
      expect(
        stages,
        containsAllInOrder([
          ShareProgressStage.sending,
          ShareProgressStage.sent,
          null,
        ]),
      );
    });

    test('a failure stays up with its reason until closed', () async {
      insert = (_) async => throw Exception('offline');

      await viewModel.handleSharedFiles([text('hello')]);
      expect(viewModel.shareProgress?.stage, ShareProgressStage.failed);
      expect(viewModel.shareProgress?.summary, 'Failed to share content');
      expect(viewModel.shareProgress?.destination, 'your devices');

      await Future<void>.delayed(
        MobileMainViewModel.shareSentLinger + const Duration(milliseconds: 50),
      );
      expect(viewModel.shareProgress?.stage, ShareProgressStage.failed);

      viewModel.dismissShareProgress();
      expect(viewModel.shareProgress, isNull);
    });

    test('a partial failure says how many went', () async {
      var calls = 0;
      insert = (inv) async {
        if (calls++ == 1) throw Exception('offline');
        return inv.positionalArguments.first as ClipboardItem;
      };

      await viewModel.handleSharedFiles([text('one'), text('two')]);
      expect(viewModel.shareProgress?.stage, ShareProgressStage.failed);
      expect(
        viewModel.shareProgress?.summary,
        'Sent 1 of 2. Failed to share content',
      );
    });

    test('nothing to send shows nothing', () async {
      await viewModel.handleSharedFiles([text('')]);
      expect(viewModel.shareProgress, isNull);
      expect(stages, isEmpty);
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
