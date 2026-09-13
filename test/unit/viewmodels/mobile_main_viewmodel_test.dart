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
      settingsService: settingsService,
    );
  });

  tearDown(() {
    viewModel.dispose();
  });

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
}
