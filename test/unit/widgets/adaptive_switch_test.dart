import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/settings_service.dart';
import 'package:ghostcopy/ui/theme/appearance.dart';
import 'package:ghostcopy/ui/widgets/adaptive_switch.dart';

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final brightness in Brightness.values) {
      testWidgets('$platform $brightness switch can first paint mid-toggle', (
        tester,
      ) async {
        appAppearance.value = brightness == Brightness.light
            ? AppThemeMode.light
            : AppThemeMode.dark;
        addTearDown(() => appAppearance.value = AppThemeMode.system);
        var value = false;
        var opacity = 0.0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform, brightness: brightness),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Material(
                  child: Center(
                    child: Opacity(
                      opacity: opacity,
                      child: AdaptiveSwitch(
                        value: value,
                        onChanged: (next) => update(() => value = next),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        update(() => value = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        update(() => opacity = 1);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AdaptiveSwitch));
        await tester.pumpAndSettle();
        expect(value, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
