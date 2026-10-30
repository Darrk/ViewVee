import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/monitor/camera_directory.dart';
import 'package:viewvee/monitor/saved_camera_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SavedCameraRepository repository;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    repository = SavedCameraRepository();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('viewvee/audio_monitor'),
          (_) async => null,
        );
  });

  String pairing() => AudioPairingCredentials.generate(
    mode: AudioPairingMode.wifi,
  ).toUriString();
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'background audio mode reaches every saved camera and newly added cameras',
    () async {
      final services = <_Service>[];
      final directory = CameraDirectory(
        repository: repository,
        serviceFactory: (_) {
          final service = _Service();
          services.add(service);
          return service;
        },
      )..setPremiumEnabled(true);
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await directory.add(pairing());
      await directory.setAppBackgrounded(true);
      await directory.add(pairing());
      expect(services.every((service) => service.backgrounded), isTrue);
      expect(services.where((service) => service.viewing), hasLength(1));
      await directory.setAppBackgrounded(false);
      expect(services.every((service) => !service.backgrounded), isTrue);
      await directory.stop();
    },
  );

  test(
    'Premium allows two cameras, rejects a third and permits replacement',
    () async {
      final services = <_Service>[];
      final directory = CameraDirectory(
        repository: repository,
        serviceFactory: (_) {
          final service = _Service();
          services.add(service);
          return service;
        },
      )..setPremiumEnabled(true);
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await directory.add(pairing());
      final second = pairing();
      await directory.add(second);
      expect(directory.canAddCamera, isFalse);
      await directory.add(second);
      await expectLater(directory.add(pairing()), throwsStateError);
      expect(await repository.load(), hasLength(2));
      expect(services, hasLength(2));
      await directory.remove(directory.cameras.first.id);
      expect(directory.canAddCamera, isTrue);
      await directory.add(pairing());
      expect(directory.cameras, hasLength(2));
      await directory.stop();
    },
  );

  test('concurrent saves cannot exceed two cameras', () async {
    await repository.remember(pairing());
    final second = repository.remember(pairing());
    final third = repository.remember(pairing());
    await expectLater(third, throwsStateError);
    await second;
    expect(await repository.load(), hasLength(2));
  });

  test('legacy excess cameras stay saved but cannot connect', () async {
    final entries = List.generate(
      3,
      (_) => SavedCamera.fromJson({'pairingUri': pairing()})!,
    );
    await const FlutterSecureStorage().write(
      key: SavedCameraRepository.storageKey,
      value: jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
    final services = <_Service>[];
    final directory = CameraDirectory(
      repository: repository,
      serviceFactory: (_) {
        final service = _Service();
        services.add(service);
        return service;
      },
    )..setPremiumEnabled(true);
    addTearDown(directory.dispose);
    await directory.start(AudioConnectionMode.wifi);
    expect(services, hasLength(2));
    expect(directory.isCameraLocked(entries.last.id), isTrue);
    await expectLater(directory.select(entries.last.id), throwsStateError);
    await expectLater(directory.add(entries.last.pairingUri), throwsStateError);
    expect(await repository.load(), hasLength(3));
    await directory.remove(entries.first.id);
    expect(directory.isCameraLocked(entries.last.id), isFalse);
    expect(services, hasLength(3));
    await directory.stop();
  });

  test(
    'stores paired cameras securely, deduplicates and preserves custom names',
    () async {
      final link = pairing();
      var cameras = await repository.remember(link);
      final id = cameras.single.id;
      await repository.rename(id, ' Dětský pokoj ');
      final uri = Uri.parse(link);
      final reordered = uri
          .replace(
            queryParameters: Map.fromEntries(
              uri.queryParameters.entries.toList().reversed,
            ),
          )
          .toString();
      cameras = await repository.remember(reordered);
      expect(cameras, hasLength(1));
      expect(cameras.single.name, 'Dětský pokoj');
      expect((await SavedCameraRepository().load()).single.pairingUri, link);
      expect(cameras.single.toJson().containsKey('state'), isFalse);
      await repository.remove(id);
      expect(await repository.load(), isEmpty);
    },
  );

  test(
    'concurrent saves retain both cameras and malformed entries are ignored',
    () async {
      await Future.wait([
        repository.remember(pairing()),
        repository.remember(pairing()),
      ]);
      expect(await repository.load(), hasLength(2));
      final valid = (await repository.load()).first.toJson();
      await const FlutterSecureStorage().write(
        key: SavedCameraRepository.storageKey,
        value: jsonEncode([
          null,
          {'pairingUri': 'invalid'},
          valid,
        ]),
      );
      expect(await repository.load(), hasLength(1));
    },
  );

  test(
    'tracks each live state and activates only the selected camera',
    () async {
      await repository.remember(pairing());
      await repository.remember(pairing());
      final services = <_Service>[];
      final directory = CameraDirectory(
        repository: repository,
        serviceFactory: (_) {
          final service = _Service();
          services.add(service);
          return service;
        },
      );
      directory.setPremiumEnabled(true);
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await settle();
      final cameras = directory.cameras;
      expect(cameras, hasLength(2));
      expect(directory.stateOf(cameras[0].id), AudioConnectionState.connected);
      expect(services[0].viewing, isTrue);
      expect(services[1].viewing, isFalse);
      services[0].talkback = true;
      await directory.select(cameras[1].id);
      expect(services[0].viewing, isFalse);
      expect(services[0].talkback, isFalse);
      expect(services[1].viewing, isTrue);
      services[0].emit(AudioConnectionState.disconnected);
      expect(
        directory.stateOf(cameras[0].id),
        AudioConnectionState.disconnected,
      );
      expect(directory.stateOf(cameras[1].id), AudioConnectionState.connected);
      await directory.remove(cameras[0].id);
      expect(services[0].stops, 1);
      expect(services[1].stops, 0);
      expect(directory.selectedService, same(services[1]));
      await directory.stop();
    },
  );

  test(
    'failed camera stays saved and refresh retries without interrupting active camera',
    () async {
      await repository.remember(pairing());
      await repository.remember(pairing());
      final services = <_Service>[];
      final directory = CameraDirectory(
        repository: repository,
        serviceFactory: (_) {
          final service = _Service()..available = services.isEmpty;
          services.add(service);
          return service;
        },
      );
      directory.setPremiumEnabled(true);
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await settle();
      expect(directory.cameras, hasLength(2));
      expect(
        directory.stateOf(directory.cameras[1].id),
        AudioConnectionState.error,
      );
      services[1].available = true;
      await directory.refresh();
      expect(services[1].reconnects, 1);
      expect(services[0].reconnects, 0);
      expect(
        directory.stateOf(directory.cameras[1].id),
        AudioConnectionState.connected,
      );
      await directory.stop();
    },
  );

  test(
    'saved name and pairing survive monitor restart and a tap retries offline camera',
    () async {
      final link = pairing();
      final saved = (await repository.remember(link)).single;
      await repository.rename(saved.id, 'Ložnice');
      final service = _Service()..available = false;
      final directory = CameraDirectory(
        repository: SavedCameraRepository(),
        serviceFactory: (_) => service,
      );
      directory.setAutoReconnectEnabled(false);
      directory.setPremiumEnabled(true);
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await settle();
      expect(directory.cameras.single.name, 'Ložnice');
      expect(directory.cameras.single.pairingUri, link);
      expect(service.joinedWith, link);
      expect(directory.stateOf(saved.id), AudioConnectionState.error);
      service.available = true;
      await directory.select(saved.id);
      await settle();
      expect(service.reconnects, 1);
      expect(directory.stateOf(saved.id), AudioConnectionState.connected);
      expect(directory.cameras, hasLength(1));
      await directory.stop();
    },
  );

  test(
    'Free restores one camera, locks extras, and keeps saved pairings on downgrade',
    () async {
      await repository.remember(pairing());
      await repository.remember(pairing());
      final saved = await repository.load();
      final services = <_Service>[];
      final directory = CameraDirectory(
        repository: repository,
        serviceFactory: (_) {
          final service = _Service();
          services.add(service);
          return service;
        },
      );
      addTearDown(directory.dispose);
      await directory.start(AudioConnectionMode.wifi);
      await settle();
      expect(services, hasLength(1));
      expect(directory.isCameraLocked(saved[1].id), isTrue);
      await expectLater(directory.select(saved[1].id), throwsStateError);
      await expectLater(directory.add(pairing()), throwsStateError);
      expect(await repository.load(), hasLength(2));
      await directory.add(saved.first.pairingUri);
      expect(services, hasLength(1));
      directory.setPremiumEnabled(true);
      await settle();
      expect(services, hasLength(2));
      await directory.select(saved[1].id);
      directory.setPremiumEnabled(false);
      await settle();
      expect(services[1].stops, greaterThan(0));
      expect(directory.selectedId, saved.first.id);
      expect(directory.cameras, hasLength(2));
      expect(await repository.load(), hasLength(2));
      await directory.stop();
    },
  );

  test('stopping during a join cannot resurrect a camera session', () async {
    await repository.remember(pairing());
    final service = _Service()..joinGate = Completer<void>();
    final directory = CameraDirectory(
      repository: repository,
      serviceFactory: (_) => service,
    );
    addTearDown(directory.dispose);
    await directory.start(AudioConnectionMode.wifi);
    await directory.stop();
    service.joinGate!.complete();
    await settle();
    expect(directory.selectedService, isNull);
    expect(service.state, AudioConnectionState.idle);
  });

  test('only the chosen connection mode is connected', () async {
    await repository.remember(pairing());
    await repository.remember(AudioPairingCredentials.generate().toUriString());
    final modes = <AudioConnectionMode>[];
    final directory = CameraDirectory(
      repository: repository,
      serviceFactory: (mode) {
        modes.add(mode);
        return _Service();
      },
    );
    addTearDown(directory.dispose);
    await directory.start(AudioConnectionMode.wifi);
    await settle();
    expect(directory.cameras, hasLength(1));
    expect(modes, [AudioConnectionMode.wifi]);
    await directory.stop();
  });
}

class _Service extends AudioMonitorService {
  AudioConnectionState current = AudioConnectionState.idle;
  bool viewing = true;
  bool backgrounded = false;
  @override
  Future<void> setAppBackgrounded(bool value) async => backgrounded = value;
  bool talkback = false;
  bool available = true;
  int stops = 0;
  int reconnects = 0;
  String? joinedWith;
  Completer<void>? joinGate;
  @override
  AudioConnectionState get state => current;
  @override
  bool get isAutoReconnecting => false;
  @override
  bool get isTalkbackEnabled => talkback;
  void emit(AudioConnectionState state) {
    current = state;
    onConnectionStateObserved?.call(state);
  }

  @override
  void setAutoReconnectEnabled(bool enabled) {}
  @override
  Future<void> setReceiverViewing(bool enabled) async => viewing = enabled;
  @override
  Future<void> setTalkbackEnabled(bool enabled) async => talkback = enabled;
  @override
  Future<bool> joinAsReceiver(String value) async {
    joinedWith = value;
    emit(AudioConnectionState.connecting);
    await joinGate?.future;
    emit(
      available ? AudioConnectionState.connected : AudioConnectionState.error,
    );
    return available;
  }

  @override
  Future<bool> reconnect() async {
    reconnects++;
    emit(
      available ? AudioConnectionState.connected : AudioConnectionState.error,
    );
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(AudioConnectionState.idle);
  }
}
