import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/audio/local_audio_signaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Bonjour discovery resolves and authenticates the saved Wi-Fi pairing',
    () async {
      final originalPlatform = BonsoirPlatformInterface.instance;
      final platform = _BonjourPlatform();
      BonsoirPlatformInterface.instance = platform;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('viewvee/audio_monitor');
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final camera = LocalAudioSignaling();
      final monitor = LocalAudioSignaling();
      addTearDown(() async {
        await monitor.hangUp();
        await camera.hangUp();
        for (final action in platform.actions) {
          await action.events.close();
        }
        BonsoirPlatformInterface.instance = originalPlatform;
        messenger.setMockMethodCallHandler(channel, null);
      });

      final credentials = AudioPairingCredentials.generate(
        mode: AudioPairingMode.wifi,
      );
      await camera.createRoom(credentials: credentials);
      expect(await monitor.joinRoom(credentials.toUriString()), isTrue);
      expect(platform.resolved, 1);
      expect(platform.actions.every((action) => action.initialized), isTrue);

      final received = Completer<Map<String, dynamic>>();
      camera.onControl = received.complete;
      await monitor.sendControl({'kind': 'viewer_activity', 'active': true});
      expect(await received.future.timeout(const Duration(seconds: 5)), {
        'kind': 'viewer_activity',
        'active': true,
      });
    },
  );
}

class _BonjourPlatform extends BonsoirPlatformInterface {
  BonsoirService? service;
  int resolved = 0;
  final actions = <_Action>[];

  @override
  BonsoirAction<BonsoirBroadcastEvent> createBroadcastAction(
    BonsoirService service, {
    bool printLogs = true,
  }) {
    this.service = service;
    final action = _Action<BonsoirBroadcastEvent>();
    actions.add(action);
    return action;
  }

  @override
  BonsoirAction<BonsoirDiscoveryEvent> createDiscoveryAction(
    String type, {
    bool printLogs = true,
  }) {
    final action = _Discovery(this);
    actions.add(action);
    return action;
  }
}

class _Action<T extends BonsoirEvent> implements BonsoirAction<T> {
  final events = StreamController<T>.broadcast();
  bool initialized = false;
  bool stopped = false;
  @override
  Stream<T> get eventStream => events.stream;
  @override
  bool get isReady => initialized && !stopped;
  @override
  bool get isStopped => stopped;
  @override
  Future<void> initialize() async => initialized = true;
  @override
  Future<void> start() async {
    expect(isReady, isTrue);
  }

  @override
  Future<void> stop() async => stopped = true;
}

class _Discovery extends _Action<BonsoirDiscoveryEvent> with ServiceResolver {
  _Discovery(this.platform);
  final _BonjourPlatform platform;
  @override
  Future<void> start() async {
    await super.start();
    events.add(BonsoirDiscoveryServiceFoundEvent(service: platform.service!));
  }

  @override
  Future<void> resolveService(BonsoirService service) async {
    platform.resolved++;
    events.add(
      BonsoirDiscoveryServiceResolvedEvent(
        service: service.copyWith(host: '127.0.0.1'),
      ),
    );
  }
}
