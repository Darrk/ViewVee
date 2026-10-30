import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/audio_signaling.dart';

class _UnavailableCamera extends AudioSignaling {
  int joins = 0;
  bool available = false;
  final values = <String>[];

  @override
  Future<bool> joinRoom(String pairingValue) async {
    joins++;
    values.add(pairingValue);
    return available;
  }

  @override
  Future<void> hangUp() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        if (call.method == 'createPeerConnection') {
          return {'peerConnectionId': 'test'};
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC/peerConnectionEventtest'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('viewvee/audio_monitor'),
      (_) async => null,
    );
  });

  testWidgets(
    'monitor keeps retrying beyond five failures and finds a returning camera',
    (tester) async {
      final signaling = _UnavailableCamera();
      final service = AudioMonitorService(
        signaling: signaling,
        mode: AudioConnectionMode.wifi,
      );
      expect(await service.joinAsReceiver('saved-pairing'), isFalse);
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
      }
      expect(signaling.joins, greaterThan(5));
      signaling.available = true;
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(service.state, AudioConnectionState.connecting);
      expect(signaling.values.toSet(), {'saved-pairing'});
      final stopped = service.stop();
      await tester.pump();
      await stopped;
      final stoppedAt = signaling.joins;
      await tester.pump(const Duration(minutes: 2));
      expect(signaling.joins, stoppedAt);
    },
  );

  testWidgets(
    'a stalled negotiation retries instead of staying on connecting forever',
    (tester) async {
      final signaling = _UnavailableCamera()..available = true;
      final service = AudioMonitorService(
        signaling: signaling,
        mode: AudioConnectionMode.wifi,
      );
      expect(await service.joinAsReceiver('saved-pairing'), isTrue);
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(signaling.joins, 2);
      final stopped = service.stop();
      await tester.pump();
      await stopped;
    },
  );
}
