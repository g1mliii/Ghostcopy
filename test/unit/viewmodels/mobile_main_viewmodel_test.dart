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
}
