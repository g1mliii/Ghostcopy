import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/notification_service.dart';
import 'package:ghostcopy/services/transformer_service.dart';
import 'package:ghostcopy/ui/viewmodels/spotlight_viewmodel.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MockAuthService extends Mock implements IAuthService {}

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

class _MockTransformerService extends Mock implements ITransformerService {}

class _MockClipboardService extends Mock implements IClipboardService {}

class _TestClipboardSyncService implements IClipboardSyncService {
  @override
  bool get isMonitoring => false;

  @override
  void Function()? onClipboardReceived;

  @override
  void Function(ClipboardItem item)? onClipboardSent;

  String? lastManualSendContent;

  @override
  Future<void> initialize() async {}

  @override
  void notifyManualSend(String content, {ClipboardContent? clipboardContent}) {
    lastManualSendContent = content;
  }

  @override
  void pauseRealtime() {}

  @override
  void reinitializeForUser() {}

  @override
  void resumeRealtime() {}

  @override
  void startClipboardMonitoring() {}

  @override
  void startPolling({Duration interval = const Duration(minutes: 5)}) {}

  @override
  void stopClipboardMonitoring() {}

  @override
  void stopPolling() {}

  int modificationTimeUpdates = 0;

  @override
  void updateClipboardModificationTime() => modificationTimeUpdates++;

  @override
  Future<void> refreshClipboardActivityWatch() async {}

  @override
  void stopClipboardActivityWatch() {}

  @override
  void dispose() {}
}

class _TestNotificationService implements INotificationService {
  final List<(String message, NotificationType type)> toasts =
      <(String, NotificationType)>[];

  @override
  void dispose() {}

  @override
  void initialize(GlobalKey<NavigatorState> navigatorKey) {}

  @override
  void showClickableToast({
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    Duration duration = const Duration(seconds: 3),
  }) {}

  @override
  void showClipboardNotification({
    required String content,
    required String deviceType,
  }) {}

  @override
  void showToast({
    required String message,
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    toasts.add((message, type));
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(ContentType.text);
    registerFallbackValue(RichTextFormat.html);
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
  late _MockTransformerService transformerService;
  late _TestClipboardSyncService clipboardSyncService;
  late _TestNotificationService notificationService;
  late SpotlightViewModel viewModel;

  setUp(() {
    authService = _MockAuthService();
    clipboardRepository = _MockClipboardRepository();
    transformerService = _MockTransformerService();
    clipboardSyncService = _TestClipboardSyncService();
    notificationService = _TestNotificationService();

    when(() => authService.currentUserId).thenReturn(null);
    when(
      () => authService.authStateChanges,
    ).thenAnswer((_) => const Stream<AuthState>.empty());

    when(() => transformerService.detectContentType(any())).thenAnswer(
      (_) async =>
          const ContentDetectionResult(type: TransformerContentType.plainText),
    );

    viewModel = SpotlightViewModel(
      authService: authService,
      clipboardRepository: clipboardRepository,
      clipboardSyncService: clipboardSyncService,
      transformerService: transformerService,
      notificationService: notificationService,
    );
  });

  tearDown(() {
    viewModel.dispose();
  });

  test('copying from history marks the clipboard as freshly changed', () async {
    // Smart auto-receive reads this to avoid overwriting a copy the user
    // just made. A refactor once dropped the call and nothing noticed.
    final clipboard = _MockClipboardService();
    when(() => clipboard.writeText(any())).thenAnswer((_) async {});
    final copying = SpotlightViewModel(
      authService: authService,
      clipboardRepository: clipboardRepository,
      clipboardSyncService: clipboardSyncService,
      transformerService: transformerService,
      notificationService: notificationService,
      clipboardService: clipboard,
    );
    addTearDown(copying.dispose);

    await copying.handleHistoryItemCopy(
      _clipboardItem(id: '1', content: 'hello'),
    );

    verify(() => clipboard.writeText('hello')).called(1);
    expect(clipboardSyncService.modificationTimeUpdates, 1);
  });

  test('a failed media download is not counted as a copy', () async {
    // downloadFile answers null for a missing path, a failed download or a
    // failed decrypt. Nothing reaches the clipboard, so smart receive must
    // not start guarding it.
    final clipboard = _MockClipboardService();
    when(
      () => clipboardRepository.downloadFile(any()),
    ).thenAnswer((_) async => null);
    final copying = SpotlightViewModel(
      authService: authService,
      clipboardRepository: clipboardRepository,
      clipboardSyncService: clipboardSyncService,
      transformerService: transformerService,
      notificationService: notificationService,
      clipboardService: clipboard,
    );
    addTearDown(copying.dispose);

    await copying.handleHistoryItemCopy(
      ClipboardItem(
        id: 'img',
        userId: 'user-123',
        content: '',
        deviceType: 'ios',
        createdAt: DateTime(2026),
        contentType: ContentType.imagePng,
        storagePath: 'user-123/img',
      ),
    );

    expect(clipboardSyncService.modificationTimeUpdates, 0);
    expect(copying.errorMessage, isNotNull);
    verifyNever(() => clipboard.writeImage(any()));
  });

  testWidgets('plain typing pauses do not repeatedly rebuild the window', (
    tester,
  ) async {
    var notifications = 0;
    viewModel.addListener(() => notifications++);
    for (var i = 0; i < 20; i++) {
      viewModel.updateContent('ordinary text $i');
      await tester.pump(const Duration(milliseconds: 301));
    }
    expect(notifications, 1);
    expect(viewModel.content, 'ordinary text 19');
    viewModel.updateContent('');
    await tester.pump(const Duration(milliseconds: 301));
    expect(notifications, 2);
    expect(viewModel.detectedContentType, isNull);
  });

  testWidgets('outdated detection cannot overwrite newer input', (
    tester,
  ) async {
    final pending = Completer<ContentDetectionResult>();
    when(
      () => transformerService.detectContentType('old'),
    ).thenAnswer((_) => pending.future);
    viewModel.updateContent('old');
    await tester.pump(const Duration(milliseconds: 301));
    viewModel.updateContent('new');
    await tester.pump(const Duration(milliseconds: 301));
    pending.complete(
      const ContentDetectionResult(type: TransformerContentType.json),
    );
    await tester.pump();
    expect(
      viewModel.detectedContentType?.type,
      TransformerContentType.plainText,
    );
  });

  testWidgets('continuous typing runs detection once after the final key', (
    tester,
  ) async {
    var notifications = 0;
    viewModel.addListener(() => notifications++);
    for (var i = 1; i <= 100; i++) {
      viewModel.updateContent('a' * i);
      await tester.pump(const Duration(milliseconds: 100));
    }
    verifyNever(() => transformerService.detectContentType(any()));
    expect(notifications, 0);

    await tester.pump(const Duration(milliseconds: 201));
    verify(() => transformerService.detectContentType('a' * 100)).called(1);
    expect(notifications, 1);

    // Once settled, no recurring detection, transform or window rebuild work.
    await tester.pump(const Duration(seconds: 30));
    verifyNoMoreInteractions(transformerService);
    expect(notifications, 1);
  });

  testWidgets('selection-only changes do not restart content detection', (
    tester,
  ) async {
    viewModel.updateContent('ordinary text');
    await tester.pump(const Duration(milliseconds: 200));
    // The controller listener also runs for caret/selection changes, but the
    // text is unchanged. Detection should retain its original deadline.
    viewModel.updateContent('ordinary text');
    await tester.pump(const Duration(milliseconds: 101));
    verify(
      () => transformerService.detectContentType('ordinary text'),
    ).called(1);
    await tester.pump(const Duration(seconds: 1));
    verifyNoMoreInteractions(transformerService);
  });

  testWidgets('rich previews still refresh while their type stays the same', (
    tester,
  ) async {
    var notifications = 0;
    viewModel.addListener(() => notifications++);
    when(() => transformerService.detectContentType(any())).thenAnswer(
      (invocation) async => ContentDetectionResult(
        type: TransformerContentType.hexColor,
        metadata: {'color': invocation.positionalArguments.first as String},
      ),
    );
    for (final color in ['#fff', '#000']) {
      viewModel.updateContent(color);
      await tester.pump(const Duration(milliseconds: 301));
    }
    expect(notifications, 2);
    expect(viewModel.detectedContentType?.metadata?['color'], '#000');
  });

  test('initialize loads history and attaches realtime callback', () async {
    final history = <ClipboardItem>[_clipboardItem(id: '1', content: 'hello')];

    when(
      () => clipboardRepository.getHistory(),
    ).thenAnswer((_) async => history);

    await viewModel.initialize();

    expect(viewModel.historyItems, history);
    expect(clipboardSyncService.onClipboardReceived, isNotNull);
    verify(() => clipboardRepository.getHistory()).called(1);
  });

  test('reloads history when the desktop auth account changes', () async {
    final authEvents = StreamController<AuthState>();
    addTearDown(authEvents.close);
    when(() => authService.currentUserId).thenReturn('old-user');
    when(
      () => authService.authStateChanges,
    ).thenAnswer((_) => authEvents.stream);
    when(
      () => clipboardRepository.getHistory(),
    ).thenAnswer((_) async => <ClipboardItem>[]);

    await viewModel.initialize();
    authEvents.add(const AuthState(AuthChangeEvent.signedOut, null));
    await Future<void>.delayed(Duration.zero);

    verify(() => clipboardRepository.getHistory()).called(2);
  });

  test('handleSend sends text and clears state on success', () async {
    when(() => authService.currentUserId).thenReturn('user-123');
    when(() => clipboardRepository.insert(any())).thenAnswer(
      (_) async => _clipboardItem(id: '123', content: 'hello world'),
    );

    viewModel.updateContent('hello world');
    await viewModel.handleSend();

    final inserted =
        verify(() => clipboardRepository.insert(captureAny())).captured.single
            as ClipboardItem;

    expect(inserted.userId, 'user-123');
    expect(inserted.content, 'hello world');
    expect(inserted.targetDeviceTypes, isNull);
    expect(clipboardSyncService.lastManualSendContent, 'hello world');
    expect(viewModel.content, isEmpty);
    expect(notificationService.toasts.last.$1, contains('Sent to all devices'));
    expect(notificationService.toasts.last.$2, NotificationType.success);
  });

  test('handleSend sets an error when user is not authenticated', () async {
    when(() => authService.currentUserId).thenReturn(null);

    viewModel.updateContent('unauthorized send');
    await viewModel.handleSend();

    verifyNever(() => clipboardRepository.insert(any()));
    expect(viewModel.errorMessage, contains('Failed to send'));
    expect(viewModel.isSending, isFalse);
  });

  test('handleSend forwards the selected target devices for HTML', () async {
    // insertRichText took no targetDeviceTypes at all, so picking "Android
    // only" and pasting HTML broadcast the clip to every device - silently
    // ignoring the selection the user had just made in the UI.
    when(() => authService.currentUserId).thenReturn('user-123');
    when(
      () => clipboardRepository.insertRichText(
        userId: any(named: 'userId'),
        deviceType: any(named: 'deviceType'),
        deviceName: any(named: 'deviceName'),
        content: any(named: 'content'),
        format: any(named: 'format'),
        targetDeviceTypes: any(named: 'targetDeviceTypes'),
      ),
    ).thenAnswer(
      (_) async => _clipboardItem(id: 'html-1', content: '<p>x</p>'),
    );

    viewModel
      ..updateContent('')
      ..updateClipboardContent(ClipboardContent.html('<p>x</p>'))
      ..togglePlatform('android');

    await viewModel.handleSend();

    verify(
      () => clipboardRepository.insertRichText(
        userId: 'user-123',
        deviceType: any(named: 'deviceType'),
        deviceName: any(named: 'deviceName'),
        content: '<p>x</p>',
        format: RichTextFormat.html,
        targetDeviceTypes: ['android'],
      ),
    ).called(1);
  });

  test('handleSend broadcasts HTML when no target is selected', () async {
    when(() => authService.currentUserId).thenReturn('user-123');
    when(
      () => clipboardRepository.insertRichText(
        userId: any(named: 'userId'),
        deviceType: any(named: 'deviceType'),
        deviceName: any(named: 'deviceName'),
        content: any(named: 'content'),
        format: any(named: 'format'),
        targetDeviceTypes: any(named: 'targetDeviceTypes'),
      ),
    ).thenAnswer(
      (_) async => _clipboardItem(id: 'html-2', content: '<p>y</p>'),
    );

    viewModel
      ..updateContent('')
      ..updateClipboardContent(ClipboardContent.html('<p>y</p>'));

    await viewModel.handleSend();

    // null, not an empty list: null is what the schema reads as "all devices".
    verify(
      () => clipboardRepository.insertRichText(
        userId: 'user-123',
        deviceType: any(named: 'deviceType'),
        deviceName: any(named: 'deviceName'),
        content: '<p>y</p>',
        format: RichTextFormat.html,
        // Stated explicitly even though it is the default: asserting that null
        // reaches the repository IS the point of this test.
        // ignore: avoid_redundant_argument_values
        targetDeviceTypes: null,
      ),
    ).called(1);
  });

  test(
    'handleSend sends image payload when text is empty and clears state on success',
    () async {
      when(() => authService.currentUserId).thenReturn('user-123');
      when(
        () => clipboardRepository.insertImage(
          userId: any(named: 'userId'),
          deviceType: any(named: 'deviceType'),
          deviceName: any(named: 'deviceName'),
          imageBytes: any(named: 'imageBytes'),
          mimeType: any(named: 'mimeType'),
          contentType: any(named: 'contentType'),
          targetDeviceTypes: any(named: 'targetDeviceTypes'),
        ),
      ).thenAnswer((_) async => _clipboardItem(id: 'img-1', content: ''));

      final imageBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      viewModel
        ..updateContent('')
        ..updateClipboardContent(
          ClipboardContent.image(imageBytes, 'image/png'),
        );

      await viewModel.handleSend();

      verify(
        () => clipboardRepository.insertImage(
          userId: 'user-123',
          deviceType: any(named: 'deviceType'),
          deviceName: any(named: 'deviceName'),
          imageBytes: imageBytes,
          mimeType: 'image/png',
          contentType: ContentType.imagePng,
        ),
      ).called(1);

      expect(clipboardSyncService.lastManualSendContent, isEmpty);
      expect(viewModel.content, isEmpty);
      expect(viewModel.clipboardContent, isNull);
      expect(viewModel.isSending, isFalse);
      expect(
        notificationService.toasts.last.$1,
        contains('Sent to all devices'),
      );
      expect(notificationService.toasts.last.$2, NotificationType.success);
    },
  );
}

ClipboardItem _clipboardItem({required String id, required String content}) {
  return ClipboardItem(
    id: id,
    userId: 'user-123',
    content: content,
    deviceType: 'windows',
    createdAt: DateTime(2026),
  );
}
