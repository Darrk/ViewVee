import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/monitor/saved_camera_repository.dart';
import 'package:viewvee/widgets/saved_camera_list.dart';

void main() {
  testWidgets(
    'shows camera names and live status and selects an inactive camera',
    (tester) async {
      final first = SavedCamera(
        credentials: AudioPairingCredentials.generate(),
        name: 'Dětský pokoj',
      );
      final second = SavedCamera(
        credentials: AudioPairingCredentials.generate(),
        name: 'Obývák',
      );
      String? selected;
      var added = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedCameraList(
              cameras: [first, second],
              selectedId: first.id,
              stateOf: (id) => id == first.id
                  ? AudioConnectionState.connected
                  : AudioConnectionState.disconnected,
              onSelect: (id) => selected = id,
              onAdd: () => added = true,
              onRefresh: () {},
              onRename: (_) {},
              onRemove: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Dětský pokoj'), findsOneWidget);
      expect(find.text('Aktivní'), findsOneWidget);
      expect(find.text('Obývák'), findsNothing);
      expect(
        tester.getSize(find.byType(SavedCameraList)).height,
        lessThanOrEqualTo(56),
      );
      await tester.tap(find.byKey(const Key('cameraListToggle')));
      await tester.pump();
      expect(find.text('Neaktivní'), findsOneWidget);
      await tester.tap(find.text('Obývák'));
      expect(selected, second.id);
      await tester.pump();
      expect(find.text('Obývák'), findsNothing);
      await tester.tap(find.byKey(const Key('cameraListToggle')));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(added, isTrue);
    },
  );
}
