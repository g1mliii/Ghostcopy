import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/account_prompt_store.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/notification_service.dart';
import 'package:ghostcopy/services/transformer_service.dart';
import 'package:ghostcopy/ui/viewmodels/spotlight_viewmodel.dart';
import 'package:ghostcopy/utils/network_errors.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MockAuthService extends Mock implements IAuthService {}

User _user({required bool anonymous}) => User(
  id: 'guest',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-01-01T00:00:00Z',
  isAnonymous: anonymous,
);

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

class _MockTransformerService extends Mock implements ITransformerService {}

class _MockClipboardService extends Mock implements IClipboardService {}

class _TestClipboardSyncService implements IClipboardSyncService {
  @override
  void ensureRealtimeConnected() {}

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

  /// Raised without an overlay, by the headless send-file path.
  final List<(String message, NotificationType type)> systemNotifications =
      <(String, NotificationType)>[];

  @override
  Future<void> showSystemNotification({
    required String message,
    NotificationType type = NotificationType.info,
  }) async => systemNotifications.add((message, type));

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
    when(
      () => clipboardRepository.lastDownloadWasOffline(any()),
    ).thenReturn(false);
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

  test('copying a file that never downloaded, offline, says so', () async {
    // Offline history shows the clip; its file lives in storage.
    final clipboard = _MockClipboardService();
    when(
      () => clipboardRepository.downloadFile(any()),
    ).thenAnswer((_) async => null);
    when(
      () => clipboardRepository.lastDownloadWasOffline(any()),
    ).thenReturn(true);
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

    expect(copying.errorMessage, offlineFileMessage);
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

  // A guest upgrade confirmed in a browser keeps its user id, so the account
  // check above skipped it and the screen kept offering Sign Up.
  test('a confirmed upgrade redraws without reloading history', () async {
    final authEvents = StreamController<AuthState>();
    addTearDown(authEvents.close);
    when(() => authService.currentUserId).thenReturn('guest');
    when(() => authService.currentUser).thenReturn(_user(anonymous: true));
    when(
      () => authService.authStateChanges,
    ).thenAnswer((_) => authEvents.stream);
    when(
      () => clipboardRepository.getHistory(),
    ).thenAnswer((_) async => <ClipboardItem>[]);
    await viewModel.initialize();
    var notified = 0;
    viewModel.addListener(() => notified++);

    authEvents.add(
      AuthState(
        AuthChangeEvent.tokenRefreshed,
        Session(
          accessToken: 'token',
          tokenType: 'bearer',
          user: _user(anonymous: false),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notified, 1);
    verify(() => clipboardRepository.getHistory()).called(1);
  });

  test('window focus checks for an upgrade confirmed elsewhere', () {
    when(
      () => authService.refreshIfAwaitingConfirmation(),
    ).thenAnswer((_) async {});

    viewModel.onWindowFocused();

    verify(() => authService.refreshIfAwaitingConfirmation()).called(1);
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

  test('an offline send says there is no internet connection', () async {
    when(() => authService.currentUserId).thenReturn('user-123');
    when(
      () => clipboardRepository.insert(any()),
    ).thenThrow(NetworkException(noInternetMessage));

    viewModel.updateContent('hello');
    await viewModel.handleSend();

    expect(viewModel.errorMessage, noInternetMessage);
    expect(viewModel.isSending, isFalse);
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

  group('account offer', () {
    late DateTime now;
    late AccountPromptStore store;
    late bool gameMode;
    late SpotlightViewModel offering;

    Future<void> build({
      bool sent = true,
      bool anonymous = true,
      bool disposeAfter = true,
    }) async {
      SharedPreferences.setMockInitialValues({
        if (sent) 'account_offer_has_sent': true,
      });
      now = DateTime(2026, 9, 30);
      store = AccountPromptStore(
        await SharedPreferences.getInstance(),
        clock: () => now,
      );
      gameMode = false;
      when(() => authService.isAnonymous).thenReturn(anonymous);
      when(
        () => authService.refreshIfAwaitingConfirmation(),
      ).thenAnswer((_) async {});
      offering = SpotlightViewModel(
        authService: authService,
        clipboardRepository: clipboardRepository,
        clipboardSyncService: clipboardSyncService,
        transformerService: transformerService,
        notificationService: notificationService,
        accountPromptStore: store,
        isGameModeActive: () => gameMode,
      );
      if (disposeAfter) addTearDown(offering.dispose);
    }

    test('shows on opening once the guest has sent a clip', () async {
      await build();
      expect(offering.showAccountOffer, isFalse);

      await offering.onWindowFocused();

      expect(offering.showAccountOffer, isTrue);
      expect(offering.showGuestBadge, isTrue);
    });

    test('waits for the first send, and that send is remembered', () async {
      await build(sent: false);
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isFalse);

      when(() => authService.currentUserId).thenReturn('guest');
      when(
        () => clipboardRepository.insert(any()),
      ).thenAnswer((_) async => _clipboardItem(id: '1', content: 'hi'));
      offering.updateContent('hi');
      await offering.handleSend();
      await Future<void>.delayed(Duration.zero);

      expect(store.hasSent, isTrue);
      // The send hid Spotlight; the card waits for the next opening.
      offering.onSpotlightHidden();
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isTrue);
    });

    test(
      'an upgrade clears the card, so a later guest does not inherit it',
      () async {
        final auth = StreamController<AuthState>.broadcast();
        addTearDown(auth.close);
        await build();
        when(() => authService.authStateChanges).thenAnswer((_) => auth.stream);
        when(() => authService.currentUserId).thenReturn('guest');
        when(
          () => clipboardRepository.getHistory(),
        ).thenAnswer((_) async => <ClipboardItem>[]);
        await offering.initialize();
        await offering.onWindowFocused();
        expect(offering.showAccountOffer, isTrue);

        Session session(User user) =>
            Session(accessToken: 'a', tokenType: 'bearer', user: user);
        auth.add(
          AuthState(
            AuthChangeEvent.userUpdated,
            session(_user(anonymous: false)),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // Signed out to a fresh guest, without restarting.
        when(() => authService.isAnonymous).thenReturn(true);
        expect(offering.showAccountOffer, isFalse);
      },
    );

    test('waits for the confirmation check before offering', () async {
      await build();
      final check = Completer<void>();
      when(
        () => authService.refreshIfAwaitingConfirmation(),
      ).thenAnswer((_) => check.future);

      final focusing = offering.onWindowFocused();
      await Future<void>.delayed(Duration.zero);
      expect(offering.showAccountOffer, isFalse);

      // The check found the upgrade confirmed in the browser.
      when(() => authService.isAnonymous).thenReturn(false);
      check.complete();
      await focusing;
      expect(offering.showAccountOffer, isFalse);
    });

    test('chains the callbacks that were already there', () async {
      var lifecycleSent = 0;
      var lifecycleReceived = 0;
      clipboardSyncService
        ..onClipboardSent = ((_) => lifecycleSent++)
        ..onClipboardReceived = (() => lifecycleReceived++);
      await build(sent: false, disposeAfter: false);
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => <ClipboardItem>[]);
      await offering.initialize();

      clipboardSyncService.onClipboardSent!(
        _clipboardItem(id: '1', content: 'auto'),
      );
      clipboardSyncService.onClipboardReceived!();
      expect(lifecycleSent, 1);
      expect(lifecycleReceived, 1);

      final original = clipboardSyncService.onClipboardSent;
      offering.dispose();
      expect(clipboardSyncService.onClipboardSent, isNot(same(original)));
      clipboardSyncService.onClipboardSent!(
        _clipboardItem(id: '2', content: 'auto'),
      );
      expect(lifecycleSent, 2);
    });

    test('a panel opened during the confirmation check wins', () async {
      await build();
      final check = Completer<void>();
      when(
        () => authService.refreshIfAwaitingConfirmation(),
      ).thenAnswer((_) => check.future);
      var panelOpen = false;

      final focusing = offering.onWindowFocused(
        composerVisible: () => !panelOpen,
      );
      panelOpen = true;
      check.complete();
      await focusing;

      expect(offering.showAccountOffer, isFalse);
    });

    test('initializing again does not stack the callbacks', () async {
      var lifecycleSent = 0;
      clipboardSyncService.onClipboardSent = (_) => lifecycleSent++;
      await build(sent: false);
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => <ClipboardItem>[]);
      await offering.initialize();
      final installed = clipboardSyncService.onClipboardSent;

      // A new SpotlightScreen binding, as after the Windows tray menu.
      await offering.initialize();

      expect(clipboardSyncService.onClipboardSent, same(installed));
      clipboardSyncService.onClipboardSent!(
        _clipboardItem(id: '1', content: 'auto'),
      );
      expect(lifecycleSent, 1);
    });

    test('an auto-send counts as the first send', () async {
      await build(sent: false);
      when(
        () => clipboardRepository.getHistory(),
      ).thenAnswer((_) async => <ClipboardItem>[]);
      await offering.initialize();

      clipboardSyncService.onClipboardSent!(
        _clipboardItem(id: '1', content: 'auto'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(store.hasSent, isTrue);
    });

    test('not used up behind a panel; shown when the panel closes', () async {
      await build();
      await offering.onWindowFocused(composerVisible: () => false);
      expect(offering.showAccountOffer, isFalse);

      offering.offerAccountIfDue();
      expect(offering.showAccountOffer, isTrue);
    });

    test('Create Account from the badge snoozes with no card up', () async {
      await build();
      expect(offering.showAccountOffer, isFalse);

      offering.dismissAccountOffer();
      await Future<void>.delayed(Duration.zero);

      expect(store.isOfferSnoozed, isTrue);
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isFalse);
    });

    test('once per run: left alone, it does not come back', () async {
      await build();
      await offering.onWindowFocused();
      // Focus moving around inside one opening keeps it up.
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isTrue);

      offering.onSpotlightHidden();
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isFalse);
    });

    test('Not now keeps it away for a week', () async {
      await build();
      await offering.onWindowFocused();
      offering.dismissAccountOffer();
      await Future<void>.delayed(Duration.zero);
      expect(offering.showAccountOffer, isFalse);

      now = now.add(const Duration(days: 6));
      expect(store.isOfferSnoozed, isTrue);
      now = now.add(const Duration(days: 2));
      expect(store.isOfferSnoozed, isFalse);
    });

    test('not during Game Mode', () async {
      await build();
      gameMode = true;
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isFalse);

      // Not used up either: the next opening outside Game Mode still gets it.
      gameMode = false;
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isTrue);
    });

    test('never for a signed-in account', () async {
      await build(anonymous: false);
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isFalse);
      expect(offering.showGuestBadge, isFalse);
    });

    test('an upgrade finishing takes the card and badge away', () async {
      await build();
      await offering.onWindowFocused();
      expect(offering.showAccountOffer, isTrue);

      when(() => authService.isAnonymous).thenReturn(false);
      expect(offering.showAccountOffer, isFalse);
      expect(offering.showGuestBadge, isFalse);
    });

    test('off entirely without a store', () async {
      when(() => authService.isAnonymous).thenReturn(true);
      when(
        () => authService.refreshIfAwaitingConfirmation(),
      ).thenAnswer((_) async {});
      await viewModel.onWindowFocused();
      expect(viewModel.showAccountOffer, isFalse);
      expect(viewModel.showGuestBadge, isFalse);
    });
  });

  group('drafts', () {
    late _MockClipboardService clipboard;
    late DateTime now;
    late SpotlightViewModel composer;
    late Directory tmp;

    setUp(() {
      clipboard = _MockClipboardService();
      now = DateTime(2026, 10, 1, 9);
      tmp = Directory.systemTemp.createTempSync('draft_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      composer = SpotlightViewModel(
        authService: authService,
        clipboardRepository: clipboardRepository,
        clipboardSyncService: clipboardSyncService,
        transformerService: transformerService,
        notificationService: notificationService,
        clipboardService: clipboard,
        clock: () => now,
      );
      addTearDown(composer.dispose);
    });

    void clipboardHolds(String text) => when(
      () => clipboard.read(),
    ).thenAnswer((_) async => ClipboardContent.text(text));

    File stage(List<int> bytes) {
      final file = File('${tmp.path}/notes.txt')..writeAsBytesSync(bytes);
      composer.setFileContent(
        ClipboardContent.file(Uint8List.fromList(bytes), 'notes.txt'),
        'File ready to send: notes.txt',
        sourcePath: file.path,
      );
      return file;
    }

    test('auto-paste fills an empty composer, and a hide clears it', () async {
      clipboardHolds('from clipboard');
      await composer.restoreOrPopulateComposer();
      expect(composer.content, 'from clipboard');
      expect(composer.hasDraft, isFalse);

      composer.onSpotlightHidden();
      expect(composer.content, isEmpty);
    });

    test('typed text survives a hide and is not auto-pasted over', () async {
      clipboardHolds('from clipboard');
      composer
        ..updateContent('half a message')
        ..onSpotlightHidden();
      expect(composer.content, 'half a message');

      await composer.restoreOrPopulateComposer();
      expect(composer.content, 'half a message');
      expect(composer.draftRestored, isTrue);
      verifyNever(() => clipboard.read());
    });

    test('a staged file keeps its path, not its bytes, while hidden', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);

      composer.onSpotlightHidden();
      expect(composer.clipboardContent, isNull);
      expect(composer.content, 'File ready to send: notes.txt');

      await composer.restoreOrPopulateComposer();
      expect(composer.clipboardContent?.fileBytes, [1, 2, 3]);
      expect(composer.clipboardContent?.filename, 'notes.txt');
    });

    test('a kept file that was deleted is dropped for auto-paste', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]).deleteSync();

      composer.onSpotlightHidden();
      await composer.restoreOrPopulateComposer();

      expect(composer.hasDraft, isFalse);
      expect(composer.clipboardContent, isNull);
      expect(composer.content, 'from clipboard');
    });

    test('a draft expires after ten minutes in the tray', () async {
      clipboardHolds('from clipboard');
      composer
        ..updateContent('half a message')
        ..onSpotlightHidden();

      now = now.add(SpotlightViewModel.draftLifetime);
      await composer.restoreOrPopulateComposer();

      expect(composer.hasDraft, isFalse);
      expect(composer.content, 'from clipboard');
    });

    test('an image with no file behind it is not kept', () {
      composer
        ..updateClipboardContent(
          ClipboardContent.image(Uint8List.fromList([9, 9]), 'image/png'),
        )
        ..updateContent('caption')
        ..onSpotlightHidden();

      expect(composer.clipboardContent, isNull);
      expect(composer.content, isEmpty);
      expect(composer.hasDraft, isFalse);
    });

    test('very long typed text is not kept', () {
      composer
        ..updateContent('x' * (SpotlightViewModel.maxKeptDraftChars + 1))
        ..onSpotlightHidden();

      expect(composer.content, isEmpty);
      expect(composer.hasDraft, isFalse);
    });

    test('focus without a hide leaves a draft alone', () async {
      // Closing the file picker refocuses the window: it used to auto-paste
      // over the file that had just been picked.
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);

      await composer.restoreOrPopulateComposer();

      expect(composer.clipboardContent?.fileBytes, [1, 2, 3]);
      verifyNever(() => clipboard.read());
    });

    test('Paste clipboard instead replaces the draft', () async {
      clipboardHolds('from clipboard');
      composer
        ..updateContent('half a message')
        ..onSpotlightHidden();
      await composer.restoreOrPopulateComposer();

      await composer.populateFromClipboard(force: true);

      expect(composer.content, 'from clipboard');
      expect(composer.hasDraft, isFalse);
      expect(composer.draftRestored, isFalse);
    });

    test('an empty clipboard does not replace the draft', () async {
      clipboardHolds('');
      composer.updateContent('half a message');

      await composer.populateFromClipboard(force: true);

      expect(composer.content, 'half a message');
      expect(composer.hasDraft, isTrue);
    });

    test('clearing the composer ends the draft', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);

      composer.clearClipboardPayload(clearText: true);
      expect(composer.hasDraft, isFalse);

      await composer.restoreOrPopulateComposer();
      expect(composer.content, 'from clipboard');
    });

    test('nothing sends while a kept file is still being read', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);
      composer.onSpotlightHidden();
      expect(composer.isRestoringDraft, isTrue);

      // Enter before the bytes are back would have sent the placeholder line.
      await composer.handleSend();

      verifyNever(() => clipboardRepository.insert(any()));
      verifyNever(
        () => clipboardRepository.insertFile(
          userId: any(named: 'userId'),
          deviceType: any(named: 'deviceType'),
          deviceName: any(named: 'deviceName'),
          fileBytes: any(named: 'fileBytes'),
          mimeType: any(named: 'mimeType'),
          contentType: any(named: 'contentType'),
          originalFilename: any(named: 'originalFilename'),
          targetDeviceTypes: any(named: 'targetDeviceTypes'),
        ),
      );
    });

    test('a file read that finishes after another hide is dropped', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);
      composer.onSpotlightHidden();

      final restoring = composer.restoreOrPopulateComposer();
      composer.onSpotlightHidden();
      await restoring;

      expect(composer.clipboardContent, isNull);
      expect(composer.hasDraft, isTrue);
      // Still timed from the first hide, and still restorable later.
      await composer.restoreOrPopulateComposer();
      expect(composer.clipboardContent?.fileBytes, [1, 2, 3]);
    });

    test('a repeated hide does not renew the ten minutes', () async {
      clipboardHolds('from clipboard');
      composer
        ..updateContent('half a message')
        ..onSpotlightHidden();

      now = now.add(SpotlightViewModel.draftLifetime);
      // Windows remounting the screen behind the tray menu.
      composer.onSpotlightHidden();
      await composer.restoreOrPopulateComposer();

      expect(composer.content, 'from clipboard');
    });

    test('a forced paste gives way to what was typed during it', () async {
      final read = Completer<ClipboardContent>();
      when(() => clipboard.read()).thenAnswer((_) => read.future);
      composer.updateContent('first');

      final pasting = composer.populateFromClipboard(force: true);
      composer.updateContent('typed meanwhile');
      read.complete(ClipboardContent.text('from clipboard'));
      await pasting;

      expect(composer.content, 'typed meanwhile');
      expect(composer.hasDraft, isTrue);
    });

    test('an expired draft takes its previews with it', () async {
      when(
        () => clipboard.read(),
      ).thenAnswer((_) async => ClipboardContent.text(''));
      composer
        ..updateContent('#ff0000')
        ..onSpotlightHidden();

      now = now.add(SpotlightViewModel.draftLifetime);
      await composer.restoreOrPopulateComposer();
      // Past the detection debounce: it was cancelled, not just pending.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(composer.content, isEmpty);
      expect(composer.detectedContentType, isNull);
      expect(composer.transformationResult, isNull);
    });

    test('typing during a file restore wins over the old file', () async {
      clipboardHolds('from clipboard');
      stage([1, 2, 3]);
      composer.onSpotlightHidden();

      final restoring = composer.restoreOrPopulateComposer();
      composer.updateContent('typed instead');
      await restoring;

      expect(composer.clipboardContent, isNull);
      expect(composer.content, 'typed instead');
      // A text draft now, so Send is not held waiting for a file.
      expect(composer.isRestoringDraft, isFalse);
      expect(composer.hasDraft, isTrue);
    });

    test('a hide during a send records what was sent', () async {
      final inserting = Completer<ClipboardItem>();
      when(() => authService.currentUserId).thenReturn('user-123');
      when(
        () => clipboardRepository.insert(any()),
      ).thenAnswer((_) => inserting.future);
      clipboardHolds('hello');
      await composer.restoreOrPopulateComposer();

      final sending = composer.handleSend();
      composer.onSpotlightHidden();
      inserting.complete(_clipboardItem(id: '1', content: 'hello'));
      await sending;

      // What stops auto-send from sending the unchanged clipboard again.
      expect(clipboardSyncService.lastManualSendContent, 'hello');
    });

    test('sending ends the draft', () async {
      when(() => authService.currentUserId).thenReturn('user-123');
      when(
        () => clipboardRepository.insert(any()),
      ).thenAnswer((_) async => _clipboardItem(id: '1', content: 'hi'));
      composer.updateContent('hi');

      await composer.handleSend();

      expect(composer.hasDraft, isFalse);
    });
  });
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
