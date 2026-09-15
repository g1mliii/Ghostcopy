import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/clipboard_service.dart';
import 'package:ghostcopy/services/impl/clipboard_sync_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/services/temp_file_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends Mock implements IClipboardRepository {}

class _Settings extends Mock implements ISettingsService {}

class _Security extends Mock implements ISecurityService {}

class _Clipboard extends Mock implements IClipboardService {}

class _TempFiles extends Mock implements ITempFileService {}

class _Supabase extends Mock implements SupabaseClient {}

class _Auth extends Mock implements GoTrueClient {}

void main() {
  late _Repository repository;
  late _Settings settings;
  late _Clipboard clipboard;
  late _TempFiles tempFiles;
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
    repository = _Repository();
    settings = _Settings();
    clipboard = _Clipboard();
    tempFiles = _TempFiles();
    final client = _Supabase();
    final auth = _Auth();
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
    );
  });

  tearDown(() => service.dispose());

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
