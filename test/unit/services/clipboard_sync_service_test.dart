import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/impl/clipboard_sync_service.dart';
import 'package:ghostcopy/services/obsidian_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/services/temp_file_service.dart';
import 'package:ghostcopy/services/webhook_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Webhook extends Mock implements IWebhookService {}

class _Obsidian extends Mock implements IObsidianService {}

class _Repository extends Mock implements IClipboardRepository {}

class _Settings extends Mock implements ISettingsService {}

class _Security extends Mock implements ISecurityService {}

class _Clipboard extends Mock implements IClipboardService {}

class _TempFiles extends Mock implements ITempFileService {}

class _Supabase extends Mock implements SupabaseClient {}

class _Auth extends Mock implements GoTrueClient {}

void main() {
  late _Webhook webhook;
  late _Obsidian obsidian;
  late _Repository repository;
  late _Settings settings;
  late _Clipboard clipboard;
  late _TempFiles tempFiles;
  late _Auth auth;
  late ClipboardSyncService service;
  late ClipboardContent clipboardValue;

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
  });

  setUp(() {
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

  tearDown(() => service.dispose());

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
