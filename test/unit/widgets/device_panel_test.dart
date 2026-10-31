import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/ui/widgets/device_list_item.dart';
import 'package:ghostcopy/ui/widgets/device_panel.dart';
import 'package:mocktail/mocktail.dart';

class _Devices extends Mock implements IDeviceService {}

Device _device(String id) => Device(
  id: id,
  userId: 'u1',
  deviceType: 'windows',
  deviceName: 'PC $id',
  lastActive: DateTime.utc(2026),
  createdAt: DateTime.utc(2026),
);

void main() {
  testWidgets('an edit made while the first fetch is out is not undone', (
    tester,
  ) async {
    final devices = _Devices();
    final firstFetch = Completer<List<Device>?>();
    var fetches = 0;
    when(
      devices.getSavedDevices,
    ).thenAnswer((_) async => [_device('a'), _device('b')]);
    when(devices.fetchUserDevices).thenAnswer((_) {
      fetches++;
      return fetches == 1 ? firstFetch.future : Future.value([_device('a')]);
    });
    when(devices.getCurrentDeviceId).thenReturn('a');
    when(() => devices.removeDevice('b')).thenAnswer((_) async => true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DevicePanel(deviceService: devices),
          ),
        ),
      ),
    );
    await tester.pump();
    // The saved list is drawn, and usable, while the fetch is out.
    expect(find.byType(DeviceListItem), findsNWidgets(2));

    final itemB = tester
        .widgetList<DeviceListItem>(find.byType(DeviceListItem))
        .firstWhere((item) => item.device.id == 'b');
    expect(await itemB.onRemove('b'), isTrue);
    await tester.pump();
    expect(find.byType(DeviceListItem), findsOneWidget);

    // The fetch that started before the removal answers with b still in it.
    firstFetch.complete([_device('a'), _device('b')]);
    await tester.pumpAndSettle();

    expect(fetches, 2);
    expect(find.byType(DeviceListItem), findsOneWidget);
    expect(find.text('PC b'), findsNothing);
  });
}
