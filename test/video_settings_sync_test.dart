import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/audio_signaling.dart';
import 'package:viewvee/audio/turn_credentials_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'receiver mute survives camera selection and replacement audio tracks',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      const channel = MethodChannel('FlutterWebRTC.Method');
      const events = MethodChannel(
        'FlutterWebRTC/peerConnectionEventmute-test',
      );
      const rendererEvents = MethodChannel('FlutterWebRTC/Texture1');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'createPeerConnection') {
          return {'peerConnectionId': 'mute-test'};
        }
        if (call.method == 'createVideoRenderer') return {'textureId': 1};
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(rendererEvents, (_) async => null);
      final receiver = AudioMonitorService(
        signaling: _Signaling(),
        mode: AudioConnectionMode.wifi,
        manageForegroundService: false,
      );
      addTearDown(() async {
        await receiver.stop();
        for (final item in [channel, events, rendererEvents]) {
          messenger.setMockMethodCallHandler(item, null);
        }
      });
      await receiver.joinAsReceiver('pairing');
      Future<void> audioTrack(String id) async {
        final track = {'id': id, 'label': id, 'kind': 'audio', 'enabled': true};
        messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': 'onTrack',
            'track': track,
            'receiver': {
              'receiverId': 'receiver',
              'track': track,
              'rtpParameters': {
                'encodings': [],
                'headerExtensions': [],
                'codecs': [],
                'rtcp': {'cname': 'test', 'reducedSize': true},
              },
            },
            'streams': [
              {
                'streamId': id,
                'ownerTag': 'mute-test',
                'audioTracks': [track],
                'videoTracks': [],
              },
            ],
          }),
          (_) {},
        );
        await tester.pump();
      }

      bool lastEnabled() =>
          calls
                  .lastWhere(
                    (call) => call.method == 'mediaStreamTrackSetEnable',
                  )
                  .arguments['enabled']
              as bool;
      await audioTrack('first');
      expect(lastEnabled(), isTrue);
      receiver.setReceiverMuted(true);
      await tester.pump();
      expect(lastEnabled(), isFalse);
      await receiver.setReceiverViewing(false);
      await receiver.setReceiverViewing(true);
      await tester.pump();
      expect(lastEnabled(), isFalse);
      await audioTrack('replacement');
      expect(lastEnabled(), isFalse);
      receiver.setReceiverMuted(false);
      await tester.pump();
      expect(lastEnabled(), isTrue);
      await receiver.setReceiverViewing(false);
      receiver.setReceiverMuted(false);
      await tester.pump();
      expect(lastEnabled(), isFalse);
      await receiver.setReceiverViewing(true);
      await tester.pump();
      expect(lastEnabled(), isTrue);
      expect(receiver.isTalkbackEnabled, isFalse);
      await tester.runAsync(receiver.stop);
    },
  );

  testWidgets(
    'paired receiver follows camera settings and sends confirmed commands',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channels = [
        MethodChannel('FlutterWebRTC.Method'),
        MethodChannel('FlutterWebRTC/peerConnectionEventtest'),
        MethodChannel('viewvee/audio_monitor'),
      ];
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'createPeerConnection') {
            return {'peerConnectionId': 'test'};
          }
          return null;
        });
      }
      final signaling = _Signaling();
      final receiver = AudioMonitorService(
        isPremium: true,
        turnCredentials: TurnCredentialsService(
          getAccessToken: ({bool forceRefresh = false}) async => null,
        ),
        signaling: signaling,
      );
      var updates = 0;
      receiver.onVideoSettingsChanged = () => updates++;
      addTearDown(() async {
        await receiver.stop();
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      expect(await receiver.joinAsReceiver('pairing'), isTrue);

      signaling.onControl!({
        'kind': 'video_settings',
        'isHd': true,
        'nightMode': true,
        'torchEnabled': true,
      });
      expect(receiver.isHd, isTrue);
      expect(receiver.nightMode, isTrue);
      expect(receiver.torchEnabled, isTrue);
      expect(updates, 1);

      signaling.onControl!({
        'kind': 'video_settings',
        'isHd': 'invalid',
        'nightMode': false,
      });
      expect(receiver.nightMode, isTrue);
      expect(updates, 1);

      signaling.onControl!({
        'kind': 'video_settings',
        'isHd': false,
        'nightMode': false,
      });
      expect(receiver.isHd, isFalse);
      expect(receiver.nightMode, isFalse);
      expect(updates, 2);
      messenger.handlePlatformMessage(
        'FlutterWebRTC/peerConnectionEventtest',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'peerConnectionState',
          'state': 'connected',
        }),
        (_) {},
      );
      await tester.pump();
      await receiver.setAppBackgrounded(true);
      var activity = signaling.controls.lastWhere(
        (message) => message['kind'] == 'viewer_activity',
      );
      expect(activity['active'], isTrue);
      expect(activity['videoEnabled'], isFalse);
      expect(receiver.isReceiverMuted, isFalse);
      await receiver.setAppBackgrounded(false);
      activity = signaling.controls.lastWhere(
        (message) => message['kind'] == 'viewer_activity',
      );
      expect(activity['videoEnabled'], isTrue);
      final request = receiver.setTorchEnabled(true);
      await tester.pump();
      final command = signaling.controls.lastWhere(
        (m) => m['kind'] == 'camera_command',
      );
      expect(command['setting'], 'torchEnabled');
      expect(command['value'], true);
      expect(receiver.torchEnabled, isFalse);
      signaling.onControl!({
        'kind': 'camera_command_result',
        'id': command['id'],
        'success': false,
      });
      expect(await request, isFalse);
      final switching = receiver.switchCamera();
      await tester.pump();
      final switchCommand = signaling.controls.lastWhere(
        (message) => message['kind'] == 'camera_command',
      );
      expect(switchCommand['setting'], 'switchCamera');
      signaling.onControl!({
        'kind': 'camera_command_result',
        'id': switchCommand['id'],
        'success': true,
      });
      await switching;
      final pending = receiver.setNightModeEnabled(true);
      await tester.pump();
      await receiver.stop();
      expect(await pending, isFalse);
    },
  );
}

class _Signaling extends AudioSignaling {
  final List<Map<String, dynamic>> controls = [];
  @override
  Future<void> sendControl(Map<String, dynamic> message) async {
    controls.add(message);
  }

  @override
  Future<bool> joinRoom(String pairingValue) async => true;
  @override
  Future<void> hangUp() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
