import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/widgets/ghost_loading_indicator.dart';

void main() {
  testWidgets(
    'visible wait announces its label and stops with reduced motion',
    (tester) async {
      final semantics = tester.ensureSemantics();

      Widget host({required bool reduceMotion, bool tickersEnabled = true}) =>
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: TickerMode(
                enabled: tickersEnabled,
                child: const Center(
                  child: GhostLoadingIndicator(label: 'Loading history…'),
                ),
              ),
            ),
          );

      await tester.pumpWidget(host(reduceMotion: false));
      expect(find.bySemanticsLabel('Loading history…'), findsOneWidget);
      semantics.dispose();
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(host(reduceMotion: true));
      expect(find.text('Loading history…'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(host(reduceMotion: false, tickersEnabled: false));
      expect(find.text('Loading history…'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(host(reduceMotion: false));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    },
  );
}
