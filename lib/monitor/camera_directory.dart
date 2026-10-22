import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/audio_monitor_service.dart';
import '../audio/audio_pairing.dart';
import 'saved_camera_repository.dart';
import 'device_limits.dart';

/// Keeps a muted, paused media connection to unselected cameras so availability
/// reflects a live authenticated connection, rather than persisted UI state.
class CameraDirectory extends ChangeNotifier {
  CameraDirectory({
    SavedCameraRepository? repository,
    AudioMonitorService Function(AudioConnectionMode)? serviceFactory,
  }) : _repository = repository ?? SavedCameraRepository(),
       _serviceFactory =
           serviceFactory ??
           ((mode) =>
               AudioMonitorService(mode: mode, manageForegroundService: false));

  final SavedCameraRepository _repository;
  final AudioMonitorService Function(AudioConnectionMode) _serviceFactory;
  final Map<String, AudioMonitorService> _services = {};
  final Set<String> _joining = {};
  List<SavedCamera> _saved = [];
  AudioConnectionMode _mode = AudioConnectionMode.wifi;
  String? _selectedId;
  bool _premium = false;
  bool _running = false;
  bool _appBackgrounded = false;
  bool _disposed = false;
  bool _autoReconnect = true;
  bool _foregroundStarted = false;
  int _generation = 0;
  Timer? _refreshTimer;

  List<SavedCamera> get cameras => _saved
      .where(
        (camera) =>
            camera.mode ==
            (_mode == AudioConnectionMode.wifi
                ? AudioPairingMode.wifi
                : AudioPairingMode.internet),
      )
      .toList();
  String? get selectedId => _selectedId;
  AudioMonitorService? get selectedService => _services[_selectedId];
  SavedCamera? get selectedCamera =>
      cameras.where((camera) => camera.id == _selectedId).firstOrNull;
  AudioConnectionState stateOf(String id) =>
      _services[id]?.state ?? AudioConnectionState.idle;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool isCameraLocked(String id) => !cameras
      .take(_premium ? DeviceLimits.cameras : 1)
      .any((camera) => camera.id == id);
  bool get canAddCamera =>
      cameras.length < (_premium ? DeviceLimits.cameras : 1);
  String get cameraLimitMessage => _premium
      ? DeviceLimits.cameraLimitMessage
      : 'Více zařízení je součástí Premium.';

  void setPremiumEnabled(bool enabled) {
    if (_premium == enabled) return;
    _premium = enabled;
    for (final service in _services.values) {
      service.setPremiumEnabled(enabled);
    }
    if (_running) {
      for (final id in _services.keys.toList()) {
        if (isCameraLocked(id)) {
          final service = _services.remove(id)!;
          service.onConnectionStateObserved = null;
          unawaited(service.stop());
        }
      }
      if (_selectedId != null && isCameraLocked(_selectedId!)) {
        _selectedId = cameras.firstOrNull?.id;
      }
      for (final camera in cameras) {
        _addService(camera);
      }
      unawaited(
        selectedService?.setReceiverViewing(true) ?? Future<void>.value(),
      );
      _notify();
    }
  }

  Future<void> start(AudioConnectionMode mode) async {
    if (mode == AudioConnectionMode.internet && !_premium) {
      throw StateError('Tato funkce vyžaduje Premium.');
    }
    await stop();
    final generation = ++_generation;
    _mode = mode;
    _running = true;
    final saved = await _repository.load();
    if (!_running || generation != _generation) return;
    _saved = saved;
    if (!cameras.any((camera) => camera.id == _selectedId) ||
        (_selectedId != null && isCameraLocked(_selectedId!))) {
      _selectedId = cameras.firstOrNull?.id;
    }
    if (cameras.isNotEmpty) await _ensureForegroundService();
    if (!_running || generation != _generation) return;
    for (final camera in cameras) {
      _addService(camera);
    }
    _notify();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_autoReconnect) unawaited(refresh());
    });
  }

  void _addService(SavedCamera camera) {
    if (isCameraLocked(camera.id) || _services.containsKey(camera.id)) return;
    final service = _serviceFactory(_mode);
    service.setPremiumEnabled(_premium);
    unawaited(service.setAppBackgrounded(_appBackgrounded));
    service.setAutoReconnectEnabled(_autoReconnect);
    unawaited(service.setReceiverViewing(camera.id == _selectedId));
    service.onConnectionStateObserved = (_) => _notify();
    _services[camera.id] = service;
    unawaited(_connect(camera, service));
  }

  Future<void> _connect(SavedCamera camera, AudioMonitorService service) async {
    if (!_running || !_joining.add(camera.id)) return;
    final generation = _generation;
    try {
      if (service.state == AudioConnectionState.idle) {
        await service.joinAsReceiver(camera.pairingUri);
      } else if (!service.isAutoReconnecting &&
          (service.state == AudioConnectionState.error ||
              service.state == AudioConnectionState.disconnected)) {
        await service.reconnect();
      }
    } catch (_) {
      // The service reports failure through its connection state. A failed
      // camera must not interrupt other cameras or expose its pairing secret.
    } finally {
      if (generation == _generation) _joining.remove(camera.id);
      if (!_running || !identical(_services[camera.id], service)) {
        await service.stop();
      }
      _notify();
    }
  }

  Future<void> refresh() async {
    if (!_running) return;
    await Future.wait(
      cameras.map((camera) async {
        final service = _services[camera.id];
        if (service != null) await _connect(camera, service);
      }),
    );
  }

  Future<void> add(String pairingUri) async {
    final parsed = SavedCamera.fromJson({'pairingUri': pairingUri});
    if (parsed == null) throw const FormatException('Invalid pairing link.');
    if ((!canAddCamera && !cameras.any((camera) => camera.id == parsed.id)) ||
        (cameras.any((camera) => camera.id == parsed.id) &&
            isCameraLocked(parsed.id))) {
      throw StateError(cameraLimitMessage);
    }
    final generation = _generation;
    final saved = await _repository.remember(pairingUri);
    if (!_running || generation != _generation) return;
    _saved = saved;
    await _ensureForegroundService();
    if (!_running || generation != _generation) return;
    final camera = cameras.firstWhere((camera) => camera.id == parsed.id);
    _addService(camera);
    await select(camera.id);
    _notify();
  }

  Future<void> select(String id) async {
    if (isCameraLocked(id)) {
      throw StateError(cameraLimitMessage);
    }
    final service = _services[id];
    if (!_running || service == null) return;
    final previous = selectedService;
    if (previous != null && !identical(previous, service)) {
      if (previous.isTalkbackEnabled) await previous.setTalkbackEnabled(false);
      await previous.setReceiverViewing(false);
    }
    _selectedId = id;
    await service.setReceiverViewing(true);
    _notify();
    final camera = cameras.firstWhere((camera) => camera.id == id);
    unawaited(_connect(camera, service));
  }

  Future<void> rename(String id, String name) async {
    _saved = await _repository.rename(id, name);
    _notify();
  }

  Future<void> remove(String id) async {
    _saved = await _repository.remove(id);
    final service = _services.remove(id);
    service?.onConnectionStateObserved = null;
    await service?.stop();
    if (_selectedId == id) {
      _selectedId = null;
      final next = cameras.firstOrNull;
      if (next != null) {
        _addService(next);
        await select(next.id);
      }
    }
    for (final camera in cameras) {
      if (_running) _addService(camera);
    }
    _notify();
  }

  Future<void> setAppBackgrounded(bool backgrounded) async {
    _appBackgrounded = backgrounded;
    await Future.wait(
      _services.values.map(
        (service) => service.setAppBackgrounded(backgrounded),
      ),
    );
  }

  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnect = enabled;
    for (final service in _services.values) {
      service.setAutoReconnectEnabled(enabled);
    }
  }

  Future<void> stop() async {
    _running = false;
    _generation++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final services = _services.values.toList();
    _services.clear();
    _joining.clear();
    for (final service in services) {
      service.onConnectionStateObserved = null;
      await service.stop();
    }
    if (_foregroundStarted &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await const MethodChannel(
          'viewvee/audio_monitor',
        ).invokeMethod<void>('stopForegroundService');
      } on PlatformException {
        /* Foreground service may already be stopped. */
      }
    }
    _foregroundStarted = false;
    _notify();
  }

  Future<void> _ensureForegroundService() async {
    if (_foregroundStarted ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    final generation = _generation;
    try {
      const channel = MethodChannel('viewvee/audio_monitor');
      await channel.invokeMethod<void>('startForegroundService', {
        'role': 'receiver',
      });
      if (!_running || generation != _generation) {
        await channel.invokeMethod<void>('stopForegroundService');
      } else {
        _foregroundStarted = true;
      }
    } on PlatformException {
      /* Monitoring remains available in foreground. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
