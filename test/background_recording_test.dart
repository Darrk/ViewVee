import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/audio_signaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const native = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC/peerConnectionEventrecording');
  const texture = MethodChannel('FlutterWebRTC/Texture1');
  late AudioMonitorService monitor;
  late _Signaling signaling;
  late List<MethodCall> calls;
  Completer<void>? startGate;
  bool failStart = false;

  setUp(() async {
    calls = [];
    startGate = null;
    failStart = false;
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'createPeerConnection':
          return {'peerConnectionId': 'recording'};
        case 'createVideoRenderer':
          return {'textureId': 1};
        case 'getStats':
          return {'stats': []};
        case 'startRecordToFile':
          await startGate?.future;
          if (failStart) throw PlatformException(code: 'recording_failed');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(texture, (_) async => null);
    signaling = _Signaling();
    monitor = AudioMonitorService(
      signaling: signaling,
      isPremium: true,
      mode: AudioConnectionMode.wifi,
      manageForegroundService: false,
    );
    await monitor.joinAsReceiver('pairing');
    const track = {
      'id': 'video',
      'label': 'video',
      'kind': 'video',
      'enabled': true,
    };
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
            'streamId': 'remote',
            'ownerTag': 'recording',
            'audioTracks': [],
            'videoTracks': [track],
          },
        ],
      }),
      (_) {},
    );
    messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(monitor.canRecord, isTrue);
  });

  tearDown(() async {
    if (startGate != null && !startGate!.isCompleted) startGate!.complete();
    await monitor.stop();
    for (final channel in [native, events, texture]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Map<String, dynamic> activity() => signaling.controls.lastWhere(
    (message) => message['kind'] == 'viewer_activity',
  );
  int stops() =>
      calls.where((call) => call.method == 'stopRecordToFile').length;

  test(
    'recording retains video on lock/app switch and stops only on explicit stop',
    () async {
      await monitor.startRecording('/tmp/test-recording.mp4');
      expect(monitor.isRecording, isTrue);
      for (final backgrounded in [true, true, false, true]) {
        await monitor.setAppBackgrounded(backgrounded);
        expect(activity()['active'], isTrue);
        expect(activity()['videoEnabled'], isTrue);
        expect(monitor.isRecording, isTrue);
        expect(stops(), 0);
      }
      await Future.wait([monitor.stopRecording(), monitor.stopRecording()]);
      expect(stops(), 1);
      expect(monitor.isRecording, isFalse);
      expect(activity()['active'], isTrue);
      expect(activity()['videoEnabled'], isFalse);
      await monitor.setAppBackgrounded(false);
      expect(activity()['videoEnabled'], isTrue);
    },
  );

  test(
    'lock while native recording starts cannot pause incoming video',
    () async {
      startGate = Completer<void>();
      final starting = monitor.startRecording('/tmp/test-recording.mp4');
      await Future<void>.delayed(Duration.zero);
      await monitor.setAppBackgrounded(true);
      expect(activity()['videoEnabled'], isTrue);
      expect(stops(), 0);
      startGate!.complete();
      await starting;
      expect(monitor.isRecording, isTrue);
      expect(activity()['videoEnabled'], isTrue);
      await monitor.stopRecording();
      expect(activity()['videoEnabled'], isFalse);
    },
  );

  test(
    'failed startup restores background audio-only mode and permits retry',
    () async {
      await monitor.setAppBackgrounded(true);
      failStart = true;
      await expectLater(
        monitor.startRecording('/tmp/test-recording.mp4'),
        throwsA(isA<PlatformException>()),
      );
      expect(monitor.isRecording, isFalse);
      expect(activity()['videoEnabled'], isFalse);
      failStart = false;
      await monitor.startRecording('/tmp/test-recording.mp4');
      expect(monitor.isRecording, isTrue);
      expect(activity()['videoEnabled'], isTrue);
    },
  );

  test(
    'session shutdown waits for a pending recorder start before finalizing',
    () async {
      startGate = Completer<void>();
      final starting = monitor.startRecording('/tmp/test-recording.mp4');
      await Future<void>.delayed(Duration.zero);
      final stopping = monitor.stop();
      await Future<void>.delayed(Duration.zero);
      expect(stops(), 0);
      startGate!.complete();
      await starting;
      await stopping;
      expect(monitor.isRecording, isFalse);
      expect(stops(), 1);
    },
  );
}

class _Signaling extends AudioSignaling {
  final controls = <Map<String, dynamic>>[];
  @override
  Future<void> sendControl(Map<String, dynamic> message) async =>
      controls.add(message);
  @override
  Future<bool> joinRoom(String pairingValue) async => true;
  @override
  Future<void> hangUp() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
