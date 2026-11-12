import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/device.dart';
import 'package:ghostcopy/ui/widgets/device_list_item.dart';

void main() {
  for (final type in ['ios', 'android', 'windows']) {
    testWidgets('renaming $type preserves its hidden identity', (tester) async {
      final device = Device(
        id: 'current',
        userId: 'me',
        deviceType: type,
        deviceName: 'Office · DEADBEEF',
        lastActive: DateTime.now(),
        createdAt: DateTime.utc(2026),
      );
      String? storedName;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceListItem(
              device: device,
              isCurrentDevice: true,
              onRename: (id, name) async {
                expect(id, 'current');
                storedName = name;
                return true;
              },
              onRemove: (_) async => true,
            ),
          ),
        ),
      );

      await tester.tap(find.text(device.displayName));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text,
        device.isMobile ? 'Office' : 'Office · DEADBEEF',
      );
      expect(field.maxLength, device.isMobile ? 244 : 255);
      await tester.enterText(find.byType(TextField), '  Travel  ');
      await tester.tap(find.byTooltip('Save device name'));
      await tester.pump();

      expect(storedName, device.isMobile ? 'Travel · DEADBEEF' : 'Travel');
    });
  }
}
