import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/ui/screens/spotlight_screen.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

void main() {
  const desktopPlatforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  });

  late IClipboardRepository repository;
  late List<ClipboardItem> clips;
  late List<String> copied;

  setUp(() {
    final today = DateTime.now();
    clips = [
      for (final (id, text, date) in [
        ('1', 'alpha', today),
        ('2', 'beta', today),
        ('3', 'gamma', DateUtils.addDaysToDate(today, -1)),
      ])
        ClipboardItem(
          id: id,
          userId: 'user',
          content: text,
          deviceType: 'windows',
          createdAt: date,
        ),
    ];
    copied = [];
    final count = ValueNotifier<int>(0);
    addTearDown(count.dispose);
    repository = _MockClipboardRepository();
    when(() => repository.undecryptableItemCount).thenReturn(count);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: 280,
              child: FocusScope(
                child: SpotlightHistoryPanel(
                  historyItems: clips,
                  isLoading: false,
                  clipboardRepository: repository,
                  onClose: () async {},
                  onItemTap: (item) => copied.add(item.id),
                  onItemDelete: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'groups by day and moves focus from search to the results',
    (tester) async {
      await pumpPanel(tester);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);

      final search = tester.widget<TextField>(find.byType(TextField));
      expect(search.focusNode!.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(search.focusNode!.hasPrimaryFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(copied, ['2']);
    },
    variant: desktopPlatforms,
  );

  testWidgets(
    'search submission applies the current query before copying',
    (tester) async {
      await pumpPanel(tester);
      await tester.enterText(find.byType(TextField), ' gamma ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(copied, ['3']);
      expect(find.text('Today'), findsNothing);
      expect(find.text('Yesterday'), findsOneWidget);
    },
    variant: desktopPlatforms,
  );

  testWidgets(
    'clip menu opens from the focused row and restores focus on Escape',
    (tester) async {
      await pumpPanel(tester);
      final trigger = find.widgetWithIcon(IconButton, Icons.more_horiz).first;
      final triggerFocus = tester.widget<IconButton>(trigger).focusNode!;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Copy to Clipboard'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(copied, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Copy to Clipboard'), findsNothing);
      expect(triggerFocus.hasPrimaryFocus, isTrue);
    },
    variant: desktopPlatforms,
  );

  testWidgets(
    'clicking the padded edge opens the link without copying the row',
    (tester) async {
      final previousLauncher = UrlLauncherPlatform.instance;
      final launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);
      clips = [
        ClipboardItem(
          id: 'link',
          userId: 'user',
          content: 'https://example.com',
          deviceType: 'android',
          createdAt: DateTime.now(),
        ),
      ];
      await pumpPanel(tester);
      final action = find.ancestor(
        of: find.byIcon(Icons.open_in_new),
        matching: find.byType(InkResponse),
      );
      final bounds = tester.getRect(action);
      expect(bounds.width, greaterThanOrEqualTo(32));
      await tester.tapAt(bounds.topLeft + const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(launcher.launched, ['https://example.com']);
      expect(copied, isEmpty);
    },
    variant: desktopPlatforms,
  );

  testWidgets(
    'link menu opens with the keyboard and keeps Copy as a separate action',
    (tester) async {
      final previousLauncher = UrlLauncherPlatform.instance;
      final launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);
      clips = [
        ClipboardItem(
          id: 'link',
          userId: 'user',
          content: 'https://example.com',
          deviceType: 'android',
          createdAt: DateTime.now(),
        ),
      ];

      await pumpPanel(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Open link'), findsOneWidget);
      expect(find.text('Copy to Clipboard'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(launcher.launched, ['https://example.com']);
      expect(copied, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy to Clipboard'));
      await tester.pumpAndSettle();
      expect(copied, ['link']);
      expect(launcher.launched, ['https://example.com']);
    },
    variant: desktopPlatforms,
  );
}
