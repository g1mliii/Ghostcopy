import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Webhook webhook;
  late _Obsidian obsidian;
  late _Repository repository;
  late _Settings settings;
  late _Clipboard clipboard;
  late _TempFiles tempFiles;
  late _Auth auth;
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
  }) => ClipboardItem(
    id: id,
    userId: 'user',
    content: 'clip $id',
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
  });

  setUp(() {
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
    final client = _Supabase();
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
    when(() => clipboard.writeImage(any())).thenAnswer((_) async {});
    when(() => clipboard.writeFilePath(any())).thenAnswer((_) async {});
    clipboardValue = const ClipboardContent.empty();
    when(clipboard.read).thenAnswer((_) async => clipboardValue);
    service = ClipboardSyncService(
      clipboardRepository: repository,
      settingsService: settings,
      securityService: _Security(),
      supabaseClient: client,
      clipboardService: clipboard,
      tempFileService: tempFiles,
      webhookService: webhook,
      obsidianService: obsidian,
    );
  });

  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChangeChannel, null);
  });

  testWidgets('manual text sends reach both integrations', (tester) async {
    service.notifyManualSend('manual clip');
    await tester.pump();
    verify(
      () => webhook.sendWebhook(
        'https://example.com/hook',
        any(that: containsPair('direction', 'sent')),
      ),
    ).called(1);
    verify(
      () => obsidian.appendToVault(
        deviceType: any(named: 'deviceType'),
        direction: any(named: 'direction'),
        vaultPath: '/vault',
        fileName: 'clipboard.md',
        content: 'manual clip',
      ),
    ).called(1);
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
        verify(
          () => obsidian.appendToVault(
            deviceType: any(named: 'deviceType'),
            direction: any(named: 'direction'),
            vaultPath: '/vault',
            fileName: 'clipboard.md',
            content: 'clip 1',
          ),
        ).called(1);
        if (behavior != AutoReceiveBehavior.always) {
          verifyNever(() => clipboard.writeText(any()));
        }
        service.stopPolling();
      },
    );
  }

  testWidgets(
    'account reinitialization invalidates the macOS pasteboard counter',
    (tester) async {
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
    },
    skip: !Platform.isMacOS,
  );

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
    late _Notifier notifier;

    setUp(() {
      // Built the way main.dart builds it: no notifier in the constructor,
      // attached afterwards. That gap is what silenced every received clip.
      notifier = _Notifier();
      service.attachNotificationService(notifier);
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
          message: 'Auto-copied content from android',
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
          message: 'New clip from android: "clip 1"',
          actionLabel: 'Copy',
          onAction: any(named: 'onAction'),
          duration: any(named: 'duration'),
        ),
      ).called(1);
      service.stopPolling();
    });
  });

  group(
    'smart auto-receive respects clipboard staleness',
    () {
      late _Notifier notifier;

      setUp(() {
        notifier = _Notifier();
        service.attachNotificationService(notifier);
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
    },
    skip: !(Platform.isMacOS || Platform.isWindows),
  );

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

        // Screen lock / sleep: the lifecycle stops it with everything else.
        service.stopClipboardActivityWatch();
        await tester.pump(const Duration(minutes: 2));
        await settle(tester);
        expect(counterReads, 3);
      },
      skip: !(Platform.isMacOS || Platform.isWindows),
    );
  });

  testWidgets('a clip that arrives before the notifier is attached is still '
      'announced once it is', (tester) async {
    // main.dart subscribes for clips before NotificationService exists.
    when(repository.getLatestItemId).thenAnswer((_) async => '1');
    when(() => repository.getById('1')).thenAnswer((_) async => clip('1'));
    service.startPolling(interval: const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    verify(() => clipboard.writeText('clip 1')).called(1);

    final attachedLate = _Notifier();
    service.attachNotificationService(attachedLate);

    verify(
      () => attachedLate.showToast(
        message: 'Auto-copied content from android',
        type: NotificationType.success,
      ),
    ).called(1);
    service.stopPolling();
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
