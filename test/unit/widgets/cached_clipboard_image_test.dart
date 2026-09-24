import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/ui/widgets/cached_clipboard_image.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repository extends Mock implements IClipboardRepository {}

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
}
