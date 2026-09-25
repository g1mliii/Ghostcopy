import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/ui/widgets/cached_clipboard_image.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends Mock implements IClipboardRepository {}

/// The tests below exercise the full-image path. Registering a thumbnail miss
/// keeps them doing that: CachedClipboardImage asks loadThumbnail first for a
/// tile-sized box and falls through to downloadFile when it returns null.
void _noThumbnail(_Repository repository) {
  registerFallbackValue(
    ClipboardItem(
      id: 'fallback',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/fallback',
    ),
  );
  when(() => repository.loadThumbnail(any())).thenAnswer((_) async => null);
}

class _Encryption extends Mock implements IEncryptionService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.com',
      publishableKey: 'test-key',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());

  testWidgets('recycled thumbnails ignore obsolete downloads', (tester) async {
    final repository = _Repository();
    _noThumbnail(repository);
    final first = ClipboardItem(
      id: 'first',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/first',
    );
    final second = ClipboardItem(
      id: 'second',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/second',
    );
    final oldDownload = Completer<Uint8List?>();
    final newDownload = Completer<Uint8List?>();
    when(
      () => repository.downloadFile(first),
    ).thenAnswer((_) => oldDownload.future);
    when(
      () => repository.downloadFile(second),
    ).thenAnswer((_) => newDownload.future);
    Widget thumbnail(ClipboardItem item) => MaterialApp(
      home: CachedClipboardImage(
        item: item,
        clipboardRepository: repository,
        width: 40,
        height: 40,
      ),
    );
    await tester.pumpWidget(thumbnail(first));
    await tester.pumpWidget(thumbnail(second));
    oldDownload.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    await tester.pump();
    // The current download is still pending: stale bytes must not be decoded.
    expect(find.byType(FutureBuilder<ui.Image>), findsNothing);
    newDownload.complete(null);
    await tester.pump();
    await tester.pump();
    verify(() => repository.downloadFile(first)).called(1);
    verify(() => repository.downloadFile(second)).called(1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('thumbnail decode releases images even when unmounted mid-decode', (
    tester,
  ) async {
    final repository = _Repository();
    _noThumbnail(repository);
    final item = ClipboardItem(
      id: 'image',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/image',
    );
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    when(() => repository.downloadFile(item)).thenAnswer((_) async => bytes);
    final created = <ui.Image>[];
    final disposed = <ui.Image>[];
    ui.Image.onCreate = created.add;
    ui.Image.onDispose = disposed.add;
    addTearDown(() {
      ui.Image.onCreate = null;
      ui.Image.onDispose = null;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CachedClipboardImage(
          item: item,
          clipboardRepository: repository,
          width: 40,
          height: 40,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(FutureBuilder<ui.Image>), findsOneWidget);
    expect(created, isEmpty);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 50 && created.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(created, isNotEmpty);
    expect(disposed, containsAll(created));
    expect(tester.takeException(), isNull);
  });
  testWidgets('a failed encrypted image retries once a new key loads', (
    tester,
  ) async {
    // Downloaded before the passphrase was in: decryption failed and the
    // thumbnail showed the error. Entering it changes the key revision, and
    // that must bring the image back without rebuilding the list item.
    final repository = _Repository();
    _noThumbnail(repository);
    final encryption = _Encryption();
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    when(() => encryption.keyRevision).thenReturn(revision);
    when(encryption.isEnabled).thenAnswer((_) async => true);
    final item = ClipboardItem(
      id: 'secret',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/secret',
      isEncrypted: true,
    );
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    var keyLoaded = false;
    when(
      () => repository.downloadFile(item),
    ).thenAnswer((_) async => keyLoaded ? png : null);

    await tester.pumpWidget(
      MaterialApp(
        home: CachedClipboardImage(
          item: item,
          clipboardRepository: repository,
          encryptionService: encryption,
          width: 40,
          height: 40,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);

    keyLoaded = true;
    revision.value++;
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.byType(FutureBuilder<ui.Image>), findsOneWidget);
    verify(() => repository.downloadFile(item)).called(2);
    await tester.pumpWidget(const SizedBox());
  });

  // The split that keeps a thumbnail out of anything that is not a preview.
  // Saving, sharing, dragging out and copying all go through downloadFile and
  // never through this widget, so the only way a thumbnail could be shown in
  // place of the real image is this size decision.
  group('thumbnail is used only for preview-sized boxes', () {
    ClipboardItem imageItem() => ClipboardItem(
      id: 'img',
      userId: 'test',
      content: '',
      deviceType: 'macos',
      createdAt: DateTime(2026),
      contentType: ContentType.imagePng,
      storagePath: 'test/img',
    );

    Future<void> pumpAt(
      WidgetTester tester,
      _Repository repository,
      double side,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CachedClipboardImage(
            item: imageItem(),
            clipboardRepository: repository,
            width: side,
            height: side,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a tile-sized box asks for the thumbnail', (tester) async {
      final repository = _Repository();
      _noThumbnail(repository);
      when(() => repository.downloadFile(any())).thenAnswer((_) async => null);

      await pumpAt(tester, repository, 40);

      verify(() => repository.loadThumbnail(any())).called(1);
    });

    testWidgets('a full-size box never asks for the thumbnail', (tester) async {
      final repository = _Repository();
      _noThumbnail(repository);
      when(() => repository.downloadFile(any())).thenAnswer((_) async => null);

      // Comfortably past ThumbnailDiskCache.servesUpTo even at 1x, so this is
      // the preview case rather than a tile.
      await pumpAt(tester, repository, 1200);

      verifyNever(() => repository.loadThumbnail(any()));
      verify(() => repository.downloadFile(any())).called(1);
    });
  });
}
