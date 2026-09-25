import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/viewmodels/mobile_main_viewmodel.dart';
import 'package:ghostcopy/ui/widgets/share_progress_overlay.dart';

void main() {
  Future<int> pump(
    WidgetTester tester,
    ShareProgressStage stage,
    String summary,
  ) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShareProgressOverlay(
            progress: ShareProgress(
              stage: stage,
              destination: 'macOS',
              summary: summary,
            ),
            onClose: () => closes++,
          ),
        ),
      ),
    );
    return closes;
  }

  testWidgets('while sending it says where, and cannot be tapped away', (
    tester,
  ) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShareProgressOverlay(
            progress: const ShareProgress(
              stage: ShareProgressStage.sending,
              destination: 'macOS',
              summary: 'photo.jpg',
            ),
            onClose: () => closes++,
          ),
        ),
      ),
    );
    expect(find.text('Sending to macOS'), findsOneWidget);
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('Close'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    expect(closes, 0);
  });

  testWidgets('sent says so', (tester) async {
    await pump(tester, ShareProgressStage.sent, 'photo.jpg');
    expect(find.text('Sent to macOS'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('a failure shows its reason and closes', (tester) async {
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShareProgressOverlay(
            progress: const ShareProgress(
              stage: ShareProgressStage.failed,
              destination: 'macOS',
              summary: 'photo.jpg is too large (max 10MB)',
            ),
            onClose: () => closes++,
          ),
        ),
      ),
    );
    expect(find.text('Couldn’t send'), findsOneWidget);
    expect(find.text('photo.jpg is too large (max 10MB)'), findsOneWidget);

    await tester.tap(find.text('Close'));
    expect(closes, 1);
  });
}
