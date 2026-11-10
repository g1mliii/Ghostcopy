import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/ui/screens/spotlight_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockClipboardRepository extends Mock implements IClipboardRepository {}

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
}
