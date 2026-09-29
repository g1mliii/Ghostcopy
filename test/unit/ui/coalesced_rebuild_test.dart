import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/ui/coalesced_rebuild.dart';

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with CoalescedRebuild<_Probe> {
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox();
  }
}

void main() {
  // A clip arriving with the Spotlight open and idle reloaded history in the
  // ViewModel, and the screen did not redraw until the mouse moved.
  testWidgets('a rebuild requested on an idle screen asks for a frame', (
    tester,
  ) async {
    await tester.pumpWidget(const _Probe());
    await tester.pumpAndSettle();
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    final before = state.builds;
    expect(tester.binding.hasScheduledFrame, isFalse);

    state.scheduleRebuild();

    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    await tester.pump();
    expect(state.builds, before + 1);
  });
}
