import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';
import 'package:ghostcopy/services/link_handler_service.dart';
import 'package:ghostcopy/ui/widgets/clip_link_action.dart';
import 'package:image/image.dart' as img;

class _FakeHandlers implements ILinkHandlerService {
  _FakeHandlers(this.handler);

  final LinkHandler? handler;
  bool resolved = false;

  @override
  LinkHandler? cachedHandlerFor(ClipLink link) => resolved ? handler : null;

  @override
  Future<LinkHandler?> handlerFor(ClipLink link) async {
    resolved = true;
    return handler;
  }
}

Widget _glyph(ClipLink link) => MaterialApp(
  home: Center(
    child: ClipLinkGlyph(
      link: link,
      size: 20,
      appIconSize: 28,
      color: Colors.white,
    ),
  ),
);

void main() {
  final link = ClipLink.detect('https://maps.apple.com/?q=CN%20Tower')!;
  final png = img.encodePng(img.Image(width: 2, height: 2));

  tearDown(() => LinkHandlerService.instance = null);

  testWidgets('shows the app that opens it once that is known', (tester) async {
    LinkHandlerService.instance = _FakeHandlers(
      LinkHandler(name: 'Google Maps', icon: MemoryImage(png)),
    );
    expect(clipLinkActionLabel(link), 'Open in Maps');

    await tester.pumpWidget(_glyph(link));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 28);
    expect(image.semanticLabel, 'Map, opens in Google Maps');
    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(clipLinkActionLabel(link), 'Open in Google Maps');
  });

  testWidgets('keeps the generic icon when nothing is known', (tester) async {
    LinkHandlerService.instance = _FakeHandlers(null);
    await tester.pumpWidget(_glyph(link));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    expect(clipLinkActionLabel(link), 'Open in Maps');
  });

  testWidgets('a known app without a readable icon keeps the generic one', (
    tester,
  ) async {
    LinkHandlerService.instance = _FakeHandlers(
      const LinkHandler(name: 'Waze'),
    );
    await tester.pumpWidget(_glyph(link));
    await tester.pump();
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    expect(clipLinkActionLabel(link), 'Open in Waze');
  });
}
