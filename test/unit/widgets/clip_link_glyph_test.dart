import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clip_link.dart';
import 'package:ghostcopy/services/impl/link_handler_service.dart';
import 'package:ghostcopy/services/link_handler_service.dart';
import 'package:ghostcopy/ui/widgets/clip_link_action.dart';
import 'package:image/image.dart' as img;

class _FakeHandlers implements ILinkHandlerService {
  _FakeHandlers(this.handler);

  LinkHandler? handler;
  bool resolved = false;

  @override
  LinkHandler? cachedHandlerFor(ClipLink link) => resolved ? handler : null;

  @override
  Future<LinkHandler?> handlerFor(ClipLink link) async {
    // Answers a turn later, as a real lookup does, so the first frame is
    // drawn before it.
    await Future<void>.value();
    resolved = true;
    return handler;
  }
}

String _label(ClipLink link) => clipLinkActionLabel(
  link,
  LinkHandlerService.instance.cachedHandlerFor(link),
);

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

  testWidgets('a retained row redraws a handler refreshed by another row', (
    tester,
  ) async {
    var now = DateTime(2026);
    await withClock(Clock(() => now), () async {
      final service = _FakeHandlers(const LinkHandler(name: 'Old Browser'));
      LinkHandlerService.instance = service;
      final rowKey = GlobalKey();

      Widget row() => MaterialApp(
        home: ClipLinkHandlerBuilder(
          key: rowKey,
          link: link,
          builder: (context, handler) =>
              Text(clipLinkActionLabel(link, handler)),
        ),
      );

      await tester.pumpWidget(row());
      await tester.pump();
      expect(find.text('Open in Old Browser'), findsOneWidget);
      final originalState = rowKey.currentState;

      // Another row has refreshed the shared service while this one stayed
      // mounted. Its next build schedules its own refresh after the frame.
      service.handler = const LinkHandler(name: 'New Browser');
      now = now.add(
        CachingLinkHandlerService.maxAge + const Duration(seconds: 1),
      );
      await tester.pumpWidget(row());
      expect(rowKey.currentState, same(originalState));
      await tester.pump();

      expect(find.text('Open in New Browser'), findsOneWidget);
      expect(find.text('Open in Old Browser'), findsNothing);
    });
  });

  testWidgets('shows the app that opens it once that is known', (tester) async {
    LinkHandlerService.instance = _FakeHandlers(
      LinkHandler(name: 'Google Maps', icon: MemoryImage(png)),
    );
    expect(_label(link), 'Open in Maps');

    await tester.pumpWidget(_glyph(link));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 28);
    expect(image.semanticLabel, 'Map, opens in Google Maps');
    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(_label(link), 'Open in Google Maps');
  });

  testWidgets('keeps the generic icon when nothing is known', (tester) async {
    LinkHandlerService.instance = _FakeHandlers(null);
    await tester.pumpWidget(_glyph(link));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    expect(_label(link), 'Open in Maps');
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
    expect(_label(link), 'Open in Waze');
  });

  test('calls, meetings and parcels keep their own wording', () async {
    final service = _FakeHandlers(const LinkHandler(name: 'Safari'));
    LinkHandlerService.instance = service;
    final meeting = ClipLink.detect('https://zoom.us/j/81234567890')!;
    final parcel = ClipLink.detect('1Z879E930346834440')!;
    final song = ClipLink.detect('https://open.spotify.com/track/abc')!;
    await service.handlerFor(meeting);

    expect(_label(meeting), 'Join meeting');
    expect(_label(parcel), 'Track package');
    expect(_label(song), 'Open in Safari');
  });

  testWidgets('the Open tooltip names the app once it is known', (
    tester,
  ) async {
    LinkHandlerService.instance = _FakeHandlers(
      const LinkHandler(name: 'Google Maps'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ClipLinkTooltip(link: link, child: const Text('open')),
      ),
    );
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Open in Maps',
    );
    await tester.pump();
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Open in Google Maps',
    );
  });
}
