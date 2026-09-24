import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/impl/clipboard_sync_service.dart';
import 'package:ghostcopy/services/notification_service.dart';
import 'package:ghostcopy/services/obsidian_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/services/temp_file_service.dart';
import 'package:ghostcopy/services/webhook_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Webhook extends Mock implements IWebhookService {}

class _Notifier extends Mock implements INotificationService {}

void _noop() {}

/// Let platform-channel replies and the async steps behind them land.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

class _Obsidian extends Mock implements IObsidianService {}

class _Repository extends Mock implements IClipboardRepository {}

class _Settings extends Mock implements ISettingsService {}

class _Security extends Mock implements ISecurityService {}

class _Clipboard extends Mock implements IClipboardService {}

class _TempFiles extends Mock implements ITempFileService {}

class _Supabase extends Mock implements SupabaseClient {}

class _Auth extends Mock implements GoTrueClient {}

class _Channel extends Mock implements RealtimeChannel {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Webhook webhook;
  late _Obsidian obsidian;
  late _Repository repository;
  late _Settings settings;
  late _Clipboard clipboard;
  late _TempFiles tempFiles;
  late _Auth auth;
  late _Supabase client;
  late _Security security;
  late _Notifier notifier;
  late ClipboardSyncService service;
  late ClipboardContent clipboardValue;

  /// What the native clipboard counter reports. Every write asks for it
  /// afterwards (to ignore GhostCopy's own write), and an unanswered channel
  /// would leave that call hanging, so every test answers it.
  late int pasteboard;

  /// How many times the native counter was read - the watch's cost.
  late int counterReads;
  const clipboardChangeChannel = MethodChannel(
    'com.ghostcopy.app/clipboard_change',
  );

  ClipboardItem clip(
    String id, {
    List<String>? targets,
    ContentType type = ContentType.text,
    String? content,
  }) => ClipboardItem(
    id: id,
    userId: 'user',
    content: content ?? 'clip $id',
    deviceName: 'remote-device',
    deviceType: 'android',
    createdAt: DateTime(2026),
    targetDeviceTypes: targets,
    contentType: type,
    storagePath: type.requiresStorage ? 'user/$id/file' : null,
  );

  setUpAll(() {
    registerFallbackValue(clip('fallback'));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(Duration.zero);
    registerFallbackValue(_noop);
    registerFallbackValue(PostgresChangeEvent.insert);
    registerFallbackValue(
      PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: 'user',
      ),
    );
    registerFallbackValue((PostgresChangePayload _) {});
  });

  setUp(() {
    // CI runs on Linux, which has no counter; answer it as macOS and Windows
    // do so the paths built on it are exercised there too.
    ClipboardSyncService.debugHasChangeCounter = true;
    // Sampled, as on macOS, unless a test opts into Windows' pushed changes.
    ClipboardSyncService.debugCounterPushesChanges = false;
    pasteboard = 1;
    counterReads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChangeChannel, (_) async {
          counterReads++;
          return pasteboard;
        });
    webhook = _Webhook();
    obsidian = _Obsidian();
    repository = _Repository();
    settings = _Settings();
    when(settings.getWebhookEnabled).thenAnswer((_) async => true);
    when(
      settings.getWebhookUrl,
    ).thenAnswer((_) async => 'https://example.com/hook');
    when(settings.getObsidianEnabled).thenAnswer((_) async => true);
    when(settings.getObsidianVaultPath).thenAnswer((_) async => '/vault');
    when(settings.getObsidianFileName).thenAnswer((_) async => 'clipboard.md');
    when(() => webhook.sendWebhook(any(), any())).thenAnswer((_) async {});
    when(
      () => repository.getHistory(limit: any(named: 'limit')),
    ).thenAnswer((_) async => []);
    when(
      () => obsidian.appendToVault(
        deviceType: any(named: 'deviceType'),
        direction: any(named: 'direction'),
        vaultPath: any(named: 'vaultPath'),
        fileName: any(named: 'fileName'),
        content: any(named: 'content'),
      ),
    ).thenAnswer((_) async {});
    clipboard = _Clipboard();
    tempFiles = _TempFiles();
    client = _Supabase();
    auth = _Auth();
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenReturn(
      User(
        id: 'user',
        appMetadata: {},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: '2026-01-01',
      ),
    );
    when(
      settings.getAutoReceiveBehavior,
    ).thenAnswer((_) async => AutoReceiveBehavior.always);
    when(settings.getClipboardStaleDurationMinutes).thenAnswer((_) async => 5);
    when(() => clipboard.writeText(any())).thenAnswer((_) async {});
    when(() => clipboard.writeHtml(any())).thenAnswer((_) async {});
    when(() => clipboard.writeImage(any())).thenAnswer((_) async {});
    when(() => clipboard.writeFilePath(any())).thenAnswer((_) async {});
    clipboardValue = const ClipboardContent.empty();
    when(clipboard.read).thenAnswer((_) async => clipboardValue);
    security = _Security();
    when(
      () => security.detectSensitiveDataAsync(any()),
    ).thenAnswer((_) async => DetectionResult.safe);
    notifier = _Notifier();
    service = ClipboardSyncService(
      clipboardRepository: repository,
      settingsService: settings,
      securityService: security,
      supabaseClient: client,
      clipboardService: clipboard,
      tempFileService: tempFiles,
      notificationService: notifier,
      webhookService: webhook,
      obsidianService: obsidian,
    );
  });

  tearDown(() {
    service.dispose();
    ClipboardSyncService.debugHasChangeCounter = null;
    ClipboardSyncService.debugCounterPushesChanges = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChangeChannel, null);
  });

  testWidgets('slow clipboard reads do not overlap timer ticks', (
    tester,
  ) async {
    const channel = MethodChannel('com.ghostcopy.app/clipboard_change');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => 1,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final pending = Completer<ClipboardContent>();
    when(clipboard.read).thenAnswer((_) => pending.future);
    service.startClipboardMonitoring();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    verify(clipboard.read).called(1);
    pending.completeError(Exception('Temporary read failure'));
    await tester.pump();
    when(
      clipboard.read,
    ).thenAnswer((_) async => const ClipboardContent.empty());
    await tester.pump(const Duration(seconds: 5));
    verify(clipboard.read).called(1);
    service.stopClipboardMonitoring();
  });

  testWidgets('slow history polls do not overlap and recover after failure', (
    tester,
  ) async {
    final pending = Completer<String?>();
    when(repository.getLatestItemId).thenAnswer((_) => pending.future);
    service.startPolling(interval: const Duration(seconds: 1));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    verify(repository.getLatestItemId).called(1);
    pending.completeError(Exception('Temporary network failure'));
    await tester.pump();
    when(repository.getLatestItemId).thenAnswer((_) async => null);
    await tester.pump(const Duration(seconds: 1));
    verify(repository.getLatestItemId).called(1);
    service.stopPolling();
  });

  void verifyVaultGot(String content, {String direction = 'received'}) =>
      verify(
        () => obsidian.appendToVault(
          deviceType: any(named: 'deviceType'),
          direction: direction,
          vaultPath: '/vault',
          fileName: 'clipboard.md',
          content: content,
        ),
      ).called(1);

  testWidgets('manual text sends reach both integrations', (tester) async {
    service.notifyManualSend('manual clip');
    await tester.pump();
    verify(
      () => webhook.sendWebhook(
        'https://example.com/hook',
        any(that: containsPair('direction', 'sent')),
      ),
    ).called(1);
    verifyVaultGot('manual clip', direction: 'sent');
  });

  group('a clip detected as sensitive reaches no integration', () {
    setUp(() {
      when(() => security.detectSensitiveDataAsync(any())).thenAnswer(
        (_) async => const DetectionResult(
          isSensitive: true,
          type: SensitiveDataType.apiKey,
        ),
      );
    });

    void verifyNoIntegration() {
      verifyNever(() => webhook.sendWebhook(any(), any()));
      verifyNever(
        () => obsidian.appendToVault(
          deviceType: any(named: 'deviceType'),
          direction: any(named: 'direction'),
          vaultPath: any(named: 'vaultPath'),
          fileName: any(named: 'fileName'),
          content: any(named: 'content'),
        ),
      );
    }

    testWidgets('when sent by hand from the Spotlight', (tester) async {
      service.notifyManualSend('sk_live_secret');
      await settle(tester);
      verifyNoIntegration();
    });

    testWidgets('when received from another device', (tester) async {
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNoIntegration();
      // The copy policy is untouched: only the integrations are withheld.
      verify(() => clipboard.writeText('clip 1')).called(1);
      service.stopPolling();
    });
  });

  group('a clip seen once is not received again by a later poll', () {
    late _Channel channel;
    late void Function(PostgresChangePayload) onInsert;

    setUp(() {
      channel = _Channel();
      when(() => client.channel('clipboard_changes')).thenReturn(channel);
      when(
        () => channel.onPostgresChanges(
          event: any(named: 'event'),
          schema: any(named: 'schema'),
          table: any(named: 'table'),
          filter: any(named: 'filter'),
          callback: any(named: 'callback'),
        ),
      ).thenAnswer((invocation) {
        onInsert =
            invocation.namedArguments[#callback]
                as void Function(PostgresChangePayload);
        return channel;
      });
      when(channel.subscribe).thenReturn(channel);
      when(channel.unsubscribe).thenAnswer((_) async => 'ok');
      when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    });

    testWidgets('after it arrived over realtime', (tester) async {
      when(repository.getLatestItemId).thenAnswer((_) async => null);
      service.resumeRealtime();
      await settle(tester);

      onInsert(
        PostgresChangePayload(
          schema: 'public',
          table: 'clipboard',
          commitTimestamp: DateTime(2026),
          eventType: PostgresChangeEvent.insert,
          newRecord: {'id': 1, 'device_name': 'remote-device'},
          oldRecord: const {},
          errors: null,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500)); // the debounce
      await settle(tester);
      verify(() => repository.getById('1')).called(1);
      verify(() => webhook.sendWebhook(any(), any())).called(1);

      // Idle in the tray: the lifecycle drops realtime for polling.
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      service
        ..pauseRealtime()
        ..startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      verifyNever(() => repository.getById('1'));
      verifyNever(() => webhook.sendWebhook(any(), any()));
      verify(() => clipboard.writeText('clip 1')).called(1);
      service.stopPolling();
    });

    testWidgets('when it was already newest as the subscription opened', (
      tester,
    ) async {
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      service.reinitializeForUser();
      await settle(tester);

      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      verifyNever(() => repository.getById('1'));
      verifyNever(() => clipboard.writeText(any()));
      service.stopPolling();
    });
  });

  testWidgets('a failed read is retried, then retired', (tester) async {
    // Windows fails the read while another process has the clipboard open;
    // the copy underneath must still be read on a later tick.
    clipboardValue = const ClipboardContent.unavailable();
    service.startClipboardMonitoring();
    for (var tick = 0; tick < 5; tick++) {
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
    }
    verify(clipboard.read).called(3);
    service.stopClipboardMonitoring();
  });

  testWidgets('a genuinely empty read is not repeated', (tester) async {
    service.startClipboardMonitoring();
    for (var tick = 0; tick < 5; tick++) {
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
    }
    verify(clipboard.read).called(1);
    service.stopClipboardMonitoring();
  });

  testWidgets('a clip whose account signed out during its download is neither '
      'written nor offered', (tester) async {
    final download = Completer<Uint8List?>();
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(
      () => repository.getById('1'),
    ).thenAnswer((_) async => clip('1', type: ContentType.imagePng));
    when(
      () => repository.downloadFile(any()),
    ).thenAnswer((_) => download.future);
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    when(() => auth.currentUser).thenReturn(null);
    download.complete(Uint8List.fromList([1, 2, 3]));
    await settle(tester);

    verifyNever(() => clipboard.writeImage(any()));
    verifyNever(
      () => notifier.showClickableToast(
        message: any(named: 'message'),
        actionLabel: any(named: 'actionLabel'),
        onAction: any(named: 'onAction'),
        duration: any(named: 'duration'),
      ),
    );
    service.stopPolling();
  });

  for (final behavior in AutoReceiveBehavior.values) {
    testWidgets(
      'received clips reach integrations with ${behavior.name} copying',
      (tester) async {
        when(settings.getAutoReceiveBehavior).thenAnswer((_) async => behavior);
        service.updateClipboardModificationTime();
        when(repository.getLatestItemId).thenAnswer((_) async => '1');
        when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
        service.startPolling(interval: const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        verify(
          () => webhook.sendWebhook(
            'https://example.com/hook',
            any(that: containsPair('direction', 'received')),
          ),
        ).called(1);
        verifyVaultGot('clip 1');
        if (behavior != AutoReceiveBehavior.always) {
          verifyNever(() => clipboard.writeText(any()));
        }
        service.stopPolling();
      },
    );
  }

  testWidgets('every clip in a burst reaches the integrations', (tester) async {
    // The 500ms debounce exists so the clipboard is not thrashed. It used to
    // sit in front of the integrations too, so of two clips 300ms apart only
    // the second reached the vault and the webhook.
    when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));

    service.handleRealtimeInsert({'id': 1, 'device_name': 'remote-device'});
    await tester.pump(const Duration(milliseconds: 300));
    service.handleRealtimeInsert({'id': 2, 'device_name': 'remote-device'});
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    verifyVaultGot('clip 1');
    verifyVaultGot('clip 2');
    verify(
      () => webhook.sendWebhook(
        any(),
        any(that: containsPair('direction', 'received')),
      ),
    ).called(2);
    // The clipboard itself still only takes the last one.
    verify(() => clipboard.writeText('clip 2')).called(1);
    verifyNever(() => clipboard.writeText('clip 1'));
  });

  testWidgets('polling does not deliver a clip realtime already delivered', (
    tester,
  ) async {
    // The lifecycle controller swaps realtime for polling when idle. The first
    // poll finds the newest row - the one realtime just handled.
    when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    when(repository.getLatestItemId).thenAnswer((_) async => '1');

    service.handleRealtimeInsert({'id': 1, 'device_name': 'remote-device'});
    await tester.pump(const Duration(milliseconds: 600));
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    verifyVaultGot('clip 1');
    service.stopPolling();
  });

  testWidgets('polling hands the integrations clips between two polls', (
    tester,
  ) async {
    // Idle in the tray, two clips land between polls. Only the newest is
    // copied, but the vault and the webhook must still see both.
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    when(() => repository.getById('3')).thenAnswer((_) async => clip('3'));
    when(
      () => repository.getHistory(limit: 10),
    ).thenAnswer((_) async => [clip('3'), clip('2')]);

    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    when(repository.getLatestItemId).thenAnswer((_) async => '3');
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    verifyVaultGot('clip 1');
    verifyVaultGot('clip 2');
    verifyVaultGot('clip 3');
    service.stopPolling();
  });

  testWidgets('a received HTML clip reaches the integrations as text', (
    tester,
  ) async {
    // The sending side hands over the clipboard's plain-text flavour, so the
    // same clip must not land in the vault as markup on the receiving side.
    when(() => repository.getById('1')).thenAnswer(
      (_) async => clip(
        '1',
        type: ContentType.html,
        content:
            '<meta charset="utf-8"><style>p{color:red}</style><span '
            'style="font-weight:700">Fish &amp; chips</span>',
      ),
    );

    service.handleRealtimeInsert({'id': 1, 'device_name': 'remote-device'});
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    verifyVaultGot('Fish & chips');
    verify(
      () => webhook.sendWebhook(
        any(),
        any(that: containsPair('content', 'Fish & chips')),
      ),
    ).called(1);
  });

  testWidgets('account reinitialization invalidates the pasteboard counter', (
    tester,
  ) async {
    const channel = MethodChannel('com.ghostcopy.app/clipboard_change');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => 42,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    // Exercise the account reset without opening a realtime connection.
    when(() => auth.currentUser).thenReturn(null);
    clipboardValue = ClipboardContent.image(
      Uint8List.fromList([1, 2, 3]),
      'image/png',
    );
    service.startClipboardMonitoring();
    await tester.pump(const Duration(seconds: 5));
    verify(clipboard.read).called(1);

    await tester.pump(const Duration(seconds: 5));
    verifyNever(clipboard.read);

    service.reinitializeForUser();
    await tester.pump(const Duration(seconds: 5));
    verify(clipboard.read).called(1);
    service.stopClipboardMonitoring();
  });

  testWidgets('copies the identified row even if another clip becomes newest', (
    tester,
  ) async {
    final original = clip('1');
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(
      () => repository.getHistory(limit: 1),
    ).thenAnswer((_) async => [clip('2')]);
    when(() => repository.getById('1')).thenAnswer((_) async => original);
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    verify(() => clipboard.writeText('clip 1')).called(1);
    verifyNever(() => clipboard.writeText('clip 2'));
    verifyNever(() => repository.getHistory(limit: 1));
    service.stopPolling();
  });

  group('received clips notify', () {
    setUp(() {
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    });

    testWidgets('an auto-copied clip says so', (tester) async {
      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      verify(() => clipboard.writeText('clip 1')).called(1);
      verify(
        () => notifier.showToast(
          message: 'Auto-copied content from Android',
          type: NotificationType.success,
        ),
      ).called(1);
      service.stopPolling();
    });

    testWidgets('a clip left uncopied offers to copy it', (tester) async {
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.never);

      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      verifyNever(() => clipboard.writeText(any()));
      verify(
        () => notifier.showClickableToast(
          message: 'New clip from Android: "clip 1"',
          actionLabel: 'Copy',
          onAction: any(named: 'onAction'),
          duration: any(named: 'duration'),
        ),
      ).called(1);
      service.stopPolling();
    });
  });

  group('smart auto-receive respects clipboard staleness', () {
    setUp(() {
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.smart);
      // A real write bumps the counter, which is what the watch must not
      // mistake for the user copying something.
      when(() => clipboard.writeText(any())).thenAnswer((_) async {
        pasteboard++;
      });
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    });

    Future<void> watch(WidgetTester tester) async {
      service.startClipboardActivityWatch();
      await settle(tester);
    }

    Future<void> receive(WidgetTester tester) async {
      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }

    testWidgets('a copy made just before a clip arrives is not overwritten', (
      tester,
    ) async {
      await watch(tester);
      // The user copies in another app, and the clip arrives before the
      // watch's next sample: the decision reads the counter itself.
      pasteboard++;

      await receive(tester);

      verifyNever(() => clipboard.writeText(any()));
      verify(
        () => notifier.showClickableToast(
          message: any(named: 'message'),
          actionLabel: 'Copy',
          onAction: any(named: 'onAction'),
          duration: any(named: 'duration'),
        ),
      ).called(1);
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy older than the stale window is overwritten', (
      tester,
    ) async {
      await watch(tester);
      pasteboard++;
      await tester.pump(const Duration(seconds: 30)); // the watch samples it
      await settle(tester);
      await tester.pump(const Duration(minutes: 5));
      await settle(tester);

      await receive(tester);

      verify(() => clipboard.writeText('clip 1')).called(1);
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy made while an image downloads is not overwritten', (
      tester,
    ) async {
      await watch(tester);
      when(
        () => repository.getById('1'),
      ).thenAnswer((_) async => clip('1', type: ContentType.imagePng));
      when(() => repository.downloadFile(any())).thenAnswer((_) async {
        pasteboard++; // the user copies while the download runs
        return Uint8List.fromList([1, 2, 3]);
      });

      await receive(tester);

      verifyNever(() => clipboard.writeImage(any()));
      verify(
        () => notifier.showClickableToast(
          message: any(named: 'message'),
          actionLabel: 'Copy',
          onAction: any(named: 'onAction'),
          duration: any(named: 'duration'),
        ),
      ).called(1);
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy made while a failed download ran is still protected', (
      tester,
    ) async {
      await watch(tester);
      when(
        () => repository.getById('1'),
      ).thenAnswer((_) async => clip('1', type: ContentType.imagePng));
      when(() => repository.downloadFile(any())).thenAnswer((_) async {
        pasteboard++; // the user copies, then the download fails
        return null;
      });
      await receive(tester);
      verifyNever(() => clipboard.writeImage(any()));

      // Nothing of ours was written, so that change is the user's: the next
      // clip must not overwrite it.
      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNever(() => clipboard.writeText('clip 2'));
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('copying from a notification protects that copy', (
      tester,
    ) async {
      await watch(tester);
      pasteboard++; // a fresh copy, so clip 1 is offered, not copied
      await receive(tester);
      final onAction =
          verify(
                () => notifier.showClickableToast(
                  message: any(named: 'message'),
                  actionLabel: 'Copy',
                  onAction: captureAny(named: 'onAction'),
                  duration: any(named: 'duration'),
                ),
              ).captured.single
              as Future<void> Function();

      // Six minutes on, the user's own copy is stale - then they click Copy.
      await tester.pump(const Duration(minutes: 6));
      await settle(tester);
      await onAction();
      verify(() => clipboard.writeText('clip 1')).called(1);

      // The clip they chose now counts as theirs: the next one waits.
      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNever(() => clipboard.writeText('clip 2'));
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy made while another clip downloads is not '
        'overwritten by the next clip', (tester) async {
      await watch(tester);
      final download = Completer<Uint8List?>();
      when(
        () => repository.getById('1'),
      ).thenAnswer((_) async => clip('1', type: ContentType.imagePng));
      when(
        () => repository.downloadFile(any()),
      ).thenAnswer((_) => download.future);
      await receive(tester); // clip 1 is now downloading

      pasteboard++; // the user copies in another app
      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNever(() => clipboard.writeText(any()));

      download.complete(Uint8List.fromList([1, 2, 3]));
      await settle(tester);
      verifyNever(() => clipboard.writeImage(any()));
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy made during the read-back of a write is the '
        "user's", (tester) async {
      await watch(tester);
      when(clipboard.read).thenAnswer((_) async {
        pasteboard++; // the user copies while GhostCopy reads its write back
        return clipboardValue;
      });
      await receive(tester);
      verify(() => clipboard.writeText('clip 1')).called(1);

      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNever(() => clipboard.writeText('clip 2'));
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('switching to smart takes a fresh baseline', (tester) async {
      // Copied under "always", with the watch off.
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.always);
      await receive(tester);
      verify(() => clipboard.writeText('clip 1')).called(1);

      // A morning's copying, of unknown age by the time smart is chosen.
      pasteboard += 5;
      await tester.pump(const Duration(hours: 4));
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.smart);
      await service.refreshClipboardActivityWatch();
      await settle(tester);

      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verify(() => clipboard.writeText('clip 2')).called(1);
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('a copy made just before a screen lock survives the unlock', (
      tester,
    ) async {
      await watch(tester);
      pasteboard++; // copied ten seconds before locking
      await tester.pump(const Duration(seconds: 10));
      service.stopClipboardActivityWatch(); // lock
      await settle(tester);
      await tester.pump(const Duration(minutes: 1));
      await watch(tester); // unlock

      await receive(tester);
      verifyNever(() => clipboard.writeText(any()));
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });

    testWidgets('two clips in a row are both copied', (tester) async {
      await watch(tester);
      await receive(tester);
      verify(() => clipboard.writeText('clip 1')).called(1);

      // GhostCopy's own write must not count as the user copying, or the
      // second clip inside the window would be left uncopied.
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      when(repository.getLatestItemId).thenAnswer((_) async => '2');
      when(() => repository.getById('2')).thenAnswer((_) async => clip('2'));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      verify(() => clipboard.writeText('clip 2')).called(1);
      service
        ..stopPolling()
        ..stopClipboardActivityWatch();
    });
  });

  group('the staleness watch runs only when something reads it', () {
    testWidgets('not at all unless receive is smart', (tester) async {
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.always);

      await service.refreshClipboardActivityWatch();
      await tester.pump(const Duration(minutes: 2));
      await settle(tester);

      expect(counterReads, 0);
    });

    testWidgets(
      'every thirty seconds when smart, and not at all once stopped',
      (tester) async {
        when(
          settings.getAutoReceiveBehavior,
        ).thenAnswer((_) async => AutoReceiveBehavior.smart);

        await service.refreshClipboardActivityWatch();
        await settle(tester); // the baseline read
        await tester.pump(const Duration(minutes: 1));
        await settle(tester);
        expect(counterReads, 3); // baseline plus two samples

        // Screen lock / sleep: the lifecycle stops it with everything else,
        // after one last sample.
        service.stopClipboardActivityWatch();
        await settle(tester);
        expect(counterReads, 4);
        await tester.pump(const Duration(minutes: 2));
        await settle(tester);
        expect(counterReads, 4);
      },
    );
  });

  group('where the counter is pushed (Windows)', () {
    setUp(() {
      ClipboardSyncService.debugCounterPushesChanges = true;
      when(
        settings.getAutoReceiveBehavior,
      ).thenAnswer((_) async => AutoReceiveBehavior.smart);
      when(() => clipboard.writeText(any())).thenAnswer((_) async {
        pasteboard++;
      });
      when(repository.getLatestItemId).thenAnswer((_) async => '1');
      when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    });

    /// The runner's WM_CLIPBOARDUPDATE handler, as Dart sees it.
    Future<void> pushChanged(WidgetTester tester) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.ghostcopy.app/clipboard_change',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed'),
        ),
        (_) {},
      );
      await settle(tester);
    }

    testWidgets('the watch runs no timer', (tester) async {
      await service.refreshClipboardActivityWatch();
      await settle(tester); // the baseline read
      await tester.pump(const Duration(hours: 1));
      await settle(tester);
      expect(counterReads, 1);
    });

    testWidgets('a pushed change dates the copy to when it happened', (
      tester,
    ) async {
      await service.refreshClipboardActivityWatch();
      await settle(tester);

      pasteboard++; // the user copies in another app, and Windows says so
      await pushChanged(tester);
      await tester.pump(const Duration(minutes: 6)); // then it goes stale

      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verify(() => clipboard.writeText('clip 1')).called(1);
      service.stopPolling();
    });

    testWidgets('a fresh pushed change is not overwritten', (tester) async {
      await service.refreshClipboardActivityWatch();
      await settle(tester);

      pasteboard++;
      await pushChanged(tester);

      service.startPolling(interval: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      verifyNever(() => clipboard.writeText(any()));
      service.stopPolling();
    });

    testWidgets('pushes are ignored once the watch stops', (tester) async {
      await service.refreshClipboardActivityWatch();
      await settle(tester);
      service.stopClipboardActivityWatch();
      await settle(tester);
      final reads = counterReads;

      pasteboard++;
      await pushChanged(tester);
      expect(counterReads, reads);
    });
  });

  testWidgets('a lock during a refresh keeps the watch stopped', (
    tester,
  ) async {
    final behavior = Completer<AutoReceiveBehavior>();
    when(settings.getAutoReceiveBehavior).thenAnswer((_) => behavior.future);

    final refresh = service.refreshClipboardActivityWatch(); // unlock
    service.stopClipboardActivityWatch(); // and straight back to lock
    behavior.complete(AutoReceiveBehavior.smart);
    await refresh;
    await tester.pump(const Duration(minutes: 2));
    await settle(tester);

    expect(counterReads, 0);
  });

  testWidgets('polling leaves clips for other platforms untouched', (
    tester,
  ) async {
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(
      () => repository.getById('1'),
    ).thenAnswer((_) async => clip('1', targets: ['not-this-platform']));
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    verify(() => repository.getById('1')).called(1);
    verifyNever(() => clipboard.writeText(any()));
    service.stopPolling();
  });

  testWidgets('unchanged polls do not fetch content again', (tester) async {
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    verify(() => repository.getById('1')).called(1);
    verifyNever(() => repository.getHistory(limit: any(named: 'limit')));
    service.stopPolling();
  });

  for (final type in [ContentType.imagePng, ContentType.filePdf]) {
    testWidgets(
      'received ${type.value} is not uploaded again or deleted after five seconds',
      (tester) async {
        final item = clip('1', type: type);
        final bytes = Uint8List.fromList([1, 2, 3]);
        when(repository.getLatestItemId).thenAnswer((_) async => '1');
        when(() => repository.getById('1')).thenAnswer((_) async => item);
        when(
          () => repository.downloadFile(item),
        ).thenAnswer((_) async => bytes);
        when(
          () => tempFiles.saveTempFile(any(), any()),
        ).thenAnswer((_) async => File('ghostcopy_test.pdf'));
        when(clipboard.read).thenAnswer((_) async => clipboardValue);
        if (type.isImage) {
          when(() => clipboard.writeImage(any())).thenAnswer((_) async {
            clipboardValue = ClipboardContent.image(bytes, 'image/png');
          });
        } else {
          when(() => clipboard.writeFilePath(any())).thenAnswer((_) async {
            clipboardValue = ClipboardContent.file(bytes, 'file.pdf');
          });
        }
        service.startPolling(interval: const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        service
          ..stopPolling()
          ..startClipboardMonitoring();
        await tester.pump(const Duration(seconds: 10));
        await tester.pump();
        // Any resend calls getAutoSendTargetDevices before inserting media.
        verifyNever(settings.getAutoSendTargetDevices);
        verifyNever(() => tempFiles.deleteTempFile(any()));
        service.stopClipboardMonitoring();
      },
    );
  }
}
