import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/audio/camera_pairing_repository.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/turn_credentials_service.dart';
import 'package:viewvee/audio/audio_signaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <MethodChannel>[];
  final calls = <MethodCall>[];
  final signals = <_Signaling>[];
  late AudioMonitorService camera;
  var connections = 0;
  var captures = 0;
  var stats = <Map<String, dynamic>>[];

  Map<String, dynamic> track(String id, String kind) => {
    'id': id,
    'label': id,
    'kind': kind,
    'enabled': true,
  };

  setUp(() {
    calls.clear();
    signals.clear();
    channels.clear();
    connections = 0;
    captures = 0;
    stats = [];
    void mock(String name, Future<Object?> Function(MethodCall) handler) {
      final channel = MethodChannel(name);
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, handler);
    }

    mock('FlutterWebRTC.Method', (call) async {
      calls.add(call);
      final args = call.arguments as Map? ?? {};
      switch (call.method) {
        case 'createPeerConnection':
          final id = 'pc${++connections}';
          mock('FlutterWebRTC/peerConnectionEvent$id', (_) async => null);
          return {'peerConnectionId': id};
        case 'getUserMedia':
          captures++;
          return {
            'streamId': 'stream$captures',
            'audioTracks': args['constraints']['audio'] == false
                ? []
                : [track('audio', 'audio')],
            'videoTracks': [track('video$captures', 'video')],
          };
        case 'addTrack':
          final id = args['trackId'] as String;
          return {
            'senderId': '${args['peerConnectionId']}-$id',
            'track': track(id, id == 'audio' ? 'audio' : 'video'),
            'ownsTrack': false,
            'rtpParameters': {
              'encodings': [],
              'headerExtensions': [],
              'codecs': [],
              'rtcp': {'cname': 'test', 'reducedSize': true},
            },
          };
        case 'getSenders':
          return {
            'senders': [
              for (final kind in ['audio', 'video'])
                {
                  'senderId': '${args['peerConnectionId']}-$kind',
                  'track': track(kind, kind),
                  'ownsTrack': false,
                  'rtpParameters': {
                    'encodings': [
                      {'active': true},
                    ],
                    'headerExtensions': [],
                    'codecs': [],
                    'rtcp': {'cname': 'test', 'reducedSize': true},
                  },
                },
            ],
          };
        case 'rtpSenderSetParameters':
          return {'result': true};
        case 'createVideoRenderer':
          return {'textureId': 1};
        case 'getStats':
          return {'stats': stats};
        case 'createOffer':
          return {'sdp': 'offer', 'type': 'offer'};
      }
      return null;
    });
    mock('FlutterWebRTC.Event', (_) async => null);
    mock('FlutterWebRTC/Texture1', (_) async => null);
    mock('viewvee/audio_monitor', (call) async {
      calls.add(call);
      return null;
    });
    mock('dev.fluttercommunity.plus/battery', (_) async => 100);
    camera = AudioMonitorService(
      turnCredentials: TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => null,
      ),
      isPremium: true,
      signalingFactory: () {
        final signaling = _Signaling(signals.length);
        signals.add(signaling);
        return signaling;
      },
    );
  });

  tearDown(() async {
    await camera.stop();
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> connect(WidgetTester tester, int pc, int signal) async {
    signals[signal].onControl!({
      'kind': 'detection_config',
      'motion': false,
      'sound': false,
    });
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc$pc',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await tester.pump();
  }

  test('successful camera connection records the paired monitor', () async {
    FlutterSecureStorage.setMockInitialValues({});
    await camera.stop();
    signals.clear();
    final repository = CameraPairingRepository();
    camera = AudioMonitorService(
      turnCredentials: TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => null,
      ),
      isPremium: true,
      pairingRepository: repository,
      signalingFactory: () {
        final signaling = _Signaling(signals.length);
        signals.add(signaling);
        return signaling;
      },
    );
    await camera.startTransmitter();
    expect(await repository.loadDevices(), isEmpty);
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc1',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      (await repository.loadDevices()).single.pairingUri,
      camera.pairingUri,
    );
    final second = await camera.createMonitorPairing();
    expect(await repository.loadDevices(), hasLength(1));
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc2',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect((await repository.loadDevices()).map((entry) => entry.pairingUri), [
      camera.pairingUri,
      second.pairingUri,
    ]);
  });

  testWidgets(
    'five monitor slots include disconnected reservations and reuse the last invitation',
    (tester) async {
      await camera.startTransmitter();
      for (var index = 0; index < 4; index++) {
        await connect(tester, index + 1, index);
        await camera.createMonitorPairing();
      }
      expect(signals, hasLength(5));
      expect(camera.canAddMonitor, isTrue);
      expect(
        (await camera.createMonitorPairing()).pairingUri,
        signals.last.pairingUri,
      );
      await connect(tester, 5, 4);
      expect(camera.connectedMonitorCount, 5);
      expect(camera.canAddMonitor, isFalse);
      await expectLater(camera.createMonitorPairing(), throwsStateError);
      signals.first.onRemoteHangup!();
      await expectLater(camera.createMonitorPairing(), throwsStateError);
      expect(signals, hasLength(5));
      await tester.runAsync(camera.stop);
    },
  );

  test(
    'restart restores only five legacy monitor invitations without deleting extras',
    () async {
      final pairings = List.generate(
        6,
        (_) => AudioPairingCredentials.generate().toUriString(),
      );
      FlutterSecureStorage.setMockInitialValues({
        CameraPairingRepository.storageKey: jsonEncode(
          pairings.map((link) => {'pairingUri': link}).toList(),
        ),
      });
      await camera.stop();
      signals.clear();
      camera = AudioMonitorService(
        turnCredentials: TurnCredentialsService(
          getAccessToken: ({bool forceRefresh = false}) async => null,
        ),
        isPremium: true,
        pairingRepository: CameraPairingRepository(),
        signalingFactory: () {
          final signaling = _Signaling(signals.length);
          signals.add(signaling);
          return signaling;
        },
      );
      await camera.startTransmitter();
      expect(signals, hasLength(5));
      expect(
        await CameraPairingRepository().load(AudioPairingMode.internet),
        hasLength(6),
      );
      await expectLater(camera.createMonitorPairing(), throwsStateError);
    },
  );

  test(
    'camera restart restores every saved monitor invitation without recapture per viewer',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      AudioMonitorService restoredCamera() => AudioMonitorService(
        turnCredentials: TurnCredentialsService(
          getAccessToken: ({bool forceRefresh = false}) async => null,
        ),
        isPremium: true,
        pairingRepository: CameraPairingRepository(),
        signalingFactory: () {
          final signaling = _Signaling(signals.length);
          signals.add(signaling);
          return signaling;
        },
      );
      camera = restoredCamera();
      await camera.startTransmitter();
      final primary = camera.pairingUri;
      messenger.handlePlatformMessage(
        'FlutterWebRTC/peerConnectionEventpc1',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'peerConnectionState',
          'state': 'connected',
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      final second = await camera.createMonitorPairing();
      await camera.stop();

      final previousSignals = signals.length;
      camera = restoredCamera();
      await camera.startTransmitter();
      expect(camera.pairingUri, primary);
      expect(signals.skip(previousSignals).map((signal) => signal.pairingUri), [
        primary,
        second.pairingUri,
      ]);
      expect(captures, 2);
      expect(connections, 4);
      final next = await camera.createMonitorPairing();
      expect(next.pairingUri, isNot(primary));
      expect(next.pairingUri, isNot(second.pairingUri));
      expect(
        await CameraPairingRepository().load(AudioPairingMode.internet),
        hasLength(3),
      );
    },
  );

  test('a Free viewer receives SD while another viewer keeps HD', () async {
    await camera.startTransmitter(isHd: true);
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc1',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    await camera.createMonitorPairing();
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventpc2',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    calls.clear();
    signals[1].onControl!({
      'kind': 'viewer_activity',
      'active': true,
      'hdAllowed': false,
    });
    await Future<void>.delayed(Duration.zero);
    final encodings = calls
        .where(
          (call) =>
              call.method == 'rtpSenderSetParameters' &&
              call.arguments['rtpSenderId'] == 'pc2-video',
        )
        .toList();
    expect(encodings, isNotEmpty);
    expect(
      encodings
          .last
          .arguments['parameters']['encodings'][0]['scaleResolutionDownBy'],
      1.5,
    );
    expect(camera.isHd, isTrue);
    expect(
      signals[0].controls.lastWhere(
        (m) => m['kind'] == 'video_settings',
      )['isHd'],
      isTrue,
    );
    expect(
      signals[1].controls.lastWhere(
        (m) => m['kind'] == 'video_settings',
      )['isHd'],
      isFalse,
    );
  });

  test('Free camera restores only its first saved invitation', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final repository = CameraPairingRepository();
    final primary = AudioPairingCredentials.generate(
      mode: AudioPairingMode.wifi,
    );
    final secondary = AudioPairingCredentials.generate(
      mode: AudioPairingMode.wifi,
    );
    await repository.remember(primary.toUriString());
    await repository.remember(secondary.toUriString());
    camera = AudioMonitorService(
      turnCredentials: TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => null,
      ),
      mode: AudioConnectionMode.wifi,
      pairingRepository: repository,
      signalingFactory: () {
        final signal = _Signaling(signals.length);
        signals.add(signal);
        return signal;
      },
    );
    await camera.startTransmitter();
    expect(connections, 1);
    expect(camera.pairingUri, primary.toUriString());
    await expectLater(camera.createMonitorPairing(), throwsStateError);
    expect(await repository.load(AudioPairingMode.wifi), hasLength(2));
  });

  testWidgets('two viewers share capture; quality and night mode reach both', (
    tester,
  ) async {
    await camera.startTransmitter();
    await connect(tester, 1, 0);
    final firstPairing = camera.pairingUri;
    final secondPairing = await camera.createMonitorPairing();
    expect(secondPairing.pairingUri, isNot(firstPairing));
    expect(captures, 1);
    expect(connections, 2);
    expect(
      calls
          .where((call) => call.method == 'addTrack')
          .map((call) => call.arguments['trackId']),
      ['audio', 'video1', 'audio', 'video1'],
    );
    await connect(tester, 2, 1);
    expect(camera.connectedMonitorCount, 2);
    expect(camera.state, AudioConnectionState.connected);

    await camera.setVideoQuality(isHd: true);
    final replacements = calls
        .where((call) => call.method == 'rtpSenderReplaceTrack')
        .toList();
    expect(replacements.map((call) => call.arguments['peerConnectionId']), [
      'pc1',
      'pc2',
    ]);
    expect(replacements.map((call) => call.arguments['trackId']), [
      'video2',
      'video2',
    ]);
    expect(
      calls.where(
        (call) =>
            call.method == 'trackDispose' &&
            call.arguments['trackId'] == 'audio',
      ),
      isEmpty,
    );
    await camera.setNightModeEnabled(true);
    for (final signal in signals) {
      expect(
        signal.controls.lastWhere(
          (message) => message['kind'] == 'video_settings',
        ),
        {
          'kind': 'video_settings',
          'isHd': true,
          'nightMode': true,
          'torchEnabled': false,
          'videoPaused': false,
        },
      );
    }
    await tester.runAsync(camera.stop);
    expect(signals.every((signal) => signal.closed), isTrue);
    expect(
      calls.where(
        (call) =>
            call.method == 'trackDispose' &&
            call.arguments['trackId'] == 'audio',
      ),
      hasLength(1),
    );
    expect(
      calls.where((call) => call.method == 'stopForegroundService'),
      hasLength(1),
    );
  });

  testWidgets(
    'second monitor controls shared camera and receives confirmation',
    (tester) async {
      await camera.startTransmitter();
      await connect(tester, 1, 0);
      await camera.createMonitorPairing();
      await connect(tester, 2, 1);
      signals[1].onControl!({
        'kind': 'camera_command',
        'id': 7,
        'setting': 'nightMode',
        'value': true,
      });
      await tester.pump();
      expect(camera.nightMode, isTrue);
      for (final signal in signals) {
        expect(
          signal.controls.lastWhere(
            (m) => m['kind'] == 'video_settings',
          )['nightMode'],
          isTrue,
        );
      }
      expect(signals[1].controls.last, {
        'kind': 'camera_command_result',
        'id': 7,
        'success': true,
      });
      signals[1].onControl!({
        'kind': 'camera_command',
        'id': 8,
        'setting': 'isHd',
        'value': true,
      });
      await tester.pump();
      expect(camera.isHd, isTrue);
      expect(signals[1].controls.last, {
        'kind': 'camera_command_result',
        'id': 8,
        'success': true,
      });
      signals[1].onControl!({
        'kind': 'camera_command',
        'id': 9,
        'setting': 'torchEnabled',
        'value': true,
      });
      await tester.pump();
      expect(camera.torchEnabled, isFalse);
      expect(signals[1].controls.last, {
        'kind': 'camera_command_result',
        'id': 9,
        'success': false,
      });
      await tester.runAsync(camera.stop);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      'background camera on $platform preserves viewer preferences and sound',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final videoPaused = platform != TargetPlatform.android;
        Future<void> connectPeer(int pc, int signal) async {
          signals[signal].onControl!({
            'kind': 'detection_config',
            'motion': false,
            'sound': false,
          });
          messenger.handlePlatformMessage(
            'FlutterWebRTC/peerConnectionEventpc$pc',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'peerConnectionState',
              'state': 'connected',
            }),
            (_) {},
          );
          await Future<void>.delayed(Duration.zero);
        }

        await camera.startTransmitter();
        await connectPeer(1, 0);
        await camera.createMonitorPairing();
        await connectPeer(2, 1);
        calls.clear();
        signals[1].onControl!({
          'kind': 'viewer_activity',
          'active': true,
          'videoEnabled': false,
        });
        await Future<void>.delayed(Duration.zero);
        final updates = calls
            .where((call) => call.method == 'rtpSenderSetParameters')
            .toList();
        expect(
          updates.every((call) => call.arguments['peerConnectionId'] == 'pc2'),
          isTrue,
        );
        bool enabled(String sender) =>
            calls
                    .lastWhere(
                      (call) =>
                          call.method == 'rtpSenderSetParameters' &&
                          call.arguments['rtpSenderId'] == sender,
                    )
                    .arguments['parameters']['encodings'][0]['active']
                as bool;
        expect(enabled('pc2-audio'), isTrue);
        expect(enabled('pc2-video'), isFalse);
        await camera.setAppBackgrounded(true);
        expect(enabled('pc1-audio'), isTrue);
        expect(enabled('pc1-video'), !videoPaused);
        expect(enabled('pc2-audio'), isTrue);
        expect(enabled('pc2-video'), isFalse);
        expect(
          calls
              .lastWhere((call) => call.method == 'mediaStreamTrackSetEnable')
              .arguments['enabled'],
          !videoPaused,
        );
        expect(
          signals.first.controls.lastWhere(
            (message) => message['kind'] == 'video_settings',
          )['videoPaused'],
          videoPaused,
        );
        stats = [
          {
            'id': 'mic',
            'type': 'media-source',
            'timestamp': 1.0,
            'values': {'kind': 'audio', 'audioLevel': 0.9},
          },
        ];
        signals.first.onControl!({
          'kind': 'detection_config',
          'sound': true,
          'motion': false,
          'sensitivity': 1,
        });
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(
          signals.first.controls.where(
            (message) =>
                message['kind'] == 'event' && message['event'] == 'sound',
          ),
          isNotEmpty,
        );
        expect(calls.where((call) => call.method == 'captureFrame'), isEmpty);
        await camera.setAppBackgrounded(false);
        expect(enabled('pc1-video'), isTrue);
        expect(enabled('pc2-video'), isFalse);
        expect(
          signals.first.controls.lastWhere(
            (message) => message['kind'] == 'video_settings',
          )['videoPaused'],
          isFalse,
        );
        expect(camera.connectedMonitorCount, 2);
        await camera.stop();
      },
    );
  }

  testWidgets('pausing one viewer stops only its media senders', (
    tester,
  ) async {
    await camera.startTransmitter();
    await connect(tester, 1, 0);
    await camera.createMonitorPairing();
    await connect(tester, 2, 1);
    signals[1].onControl!({'kind': 'viewer_activity', 'active': false});
    await tester.pump();
    var updates = calls
        .where((call) => call.method == 'rtpSenderSetParameters')
        .toList();
    expect(updates, hasLength(2));
    expect(
      updates.every((call) => call.arguments['peerConnectionId'] == 'pc2'),
      isTrue,
    );
    expect(
      updates.every(
        (call) =>
            call.arguments['parameters']['encodings'][0]['active'] == false,
      ),
      isTrue,
    );
    expect(camera.connectedMonitorCount, 2);
    signals[1].onControl!({'kind': 'viewer_activity', 'active': true});
    await tester.pump();
    updates = calls
        .where((call) => call.method == 'rtpSenderSetParameters')
        .toList();
    expect(
      updates.last.arguments['parameters']['encodings'][0]['active'],
      isTrue,
    );
    await tester.runAsync(camera.stop);
  });

  testWidgets('one viewer reconnects without closing the other connection', (
    tester,
  ) async {
    await camera.startTransmitter();
    await connect(tester, 1, 0);
    await camera.createMonitorPairing();
    await connect(tester, 2, 1);
    signals[1].onRemoteHangup!();
    expect(camera.connectedMonitorCount, 1);
    expect(camera.state, AudioConnectionState.connected);
    await tester.pump(const Duration(seconds: 3));
    expect(signals[1].rearms, 1);
    expect(signals[0].rearms, 0);
    expect(
      calls
          .where((call) => call.method == 'peerConnectionClose')
          .map((call) => call.arguments['peerConnectionId']),
      ['pc2'],
    );
    expect(captures, 1);
    await connect(tester, 3, 1);
    expect(camera.connectedMonitorCount, 2);
    await tester.runAsync(camera.stop);
  });

  testWidgets('primary viewer disconnect does not hide the remaining viewer', (
    tester,
  ) async {
    await camera.startTransmitter();
    await connect(tester, 1, 0);
    await camera.createMonitorPairing();
    await connect(tester, 2, 1);
    var hangups = 0;
    camera.onRemoteHangup = () => hangups++;
    signals[0].onRemoteHangup!();
    expect(camera.state, AudioConnectionState.connected);
    expect(camera.connectedMonitorCount, 1);
    expect(hangups, 0);
    expect(camera.isAutoReconnecting, isFalse);
    await tester.runAsync(camera.stop);
  });

  testWidgets(
    'unused invitations are reused and used pairings remain reserved',
    (tester) async {
      await camera.startTransmitter();
      expect(
        (await camera.createMonitorPairing()).pairingUri,
        camera.pairingUri,
      );
      await connect(tester, 1, 0);
      final invitations = await Future.wait([
        camera.createMonitorPairing(),
        camera.createMonitorPairing(),
      ]);
      expect(invitations[0].pairingUri, invitations[1].pairingUri);
      expect(signals, hasLength(2));
      expect(
        (await camera.createMonitorPairing()).pairingUri,
        invitations[0].pairingUri,
      );
      await connect(tester, 2, 1);
      signals[1].onRemoteHangup!();
      await tester.pump(const Duration(seconds: 3));
      final third = await camera.createMonitorPairing();
      expect(third.pairingUri, isNot(invitations[0].pairingUri));
      expect(signals, hasLength(3));
      await tester.runAsync(camera.stop);
    },
  );

  testWidgets('stopping during invitation creation releases all rooms', (
    tester,
  ) async {
    await camera.startTransmitter();
    await connect(tester, 1, 0);
    final gate = Completer<void>();
    // Hold the next room registration while the camera is stopped.
    _Signaling.nextCreate = gate;
    final invitation = camera.createMonitorPairing();
    final failure = expectLater(invitation, throwsStateError);
    await tester.pump();
    await tester.runAsync(camera.stop);
    gate.complete();
    await failure;
    expect(signals.every((signal) => signal.closed), isTrue);
    expect(connections, 1);
    expect(camera.state, AudioConnectionState.idle);
  });
}

class _Signaling extends AudioSignaling {
  _Signaling(this.id);
  final int id;
  static Completer<void>? nextCreate;
  final controls = <Map<String, dynamic>>[];
  bool closed = false;
  int rearms = 0;
  AudioPairingCredentials? _credentials;
  @override
  String get roomCode => _credentials!.roomCode;
  @override
  String get pairingUri => _credentials!.toUriString();
  @override
  Future<String> createRoom({AudioPairingCredentials? credentials}) async {
    _credentials = credentials ?? AudioPairingCredentials.generate();
    final gate = nextCreate;
    nextCreate = null;
    if (gate != null) await gate.future;
    return roomCode;
  }

  @override
  Future<void> rearmForNewPeer() async => rearms++;
  @override
  Future<void> hangUp() async => closed = true;
  @override
  Future<void> sendControl(Map<String, dynamic> message) async =>
      controls.add(message);
  @override
  Future<void> sendOffer(Map<String, dynamic> offer) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
