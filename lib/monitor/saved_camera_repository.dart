import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../audio/audio_pairing.dart';
import 'device_limits.dart';

class SavedCamera {
  SavedCamera({required this.credentials, this.name, this.isPaired = true});

  final AudioPairingCredentials credentials;
  final String? name;
  final bool isPaired;
  String get pairingUri => credentials.toUriString();
  String get id => sha256.convert(utf8.encode(pairingUri)).toString();
  String get roomCode => credentials.roomCode;
  AudioPairingMode get mode => credentials.mode;

  Map<String, dynamic> toJson() => {
    'pairingUri': pairingUri,
    'name': name,
    'paired': isPaired,
  };

  static SavedCamera? fromJson(Object? value) {
    if (value is! Map || value['pairingUri'] is! String) return null;
    final credentials = AudioPairingCredentials.tryParse(value['pairingUri']);
    if (credentials == null) return null;
    final name = value['name'];
    return SavedCamera(
      credentials: credentials,
      isPaired: value['paired'] != false,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
    );
  }
}

/// Pairing links contain authentication secrets and belong in secure storage.
class SavedCameraRepository {
  SavedCameraRepository({
    FlutterSecureStorage? storage,
    this.key = storageKey,
    this.maxPairings = DeviceLimits.cameras,
  }) : _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 'monitor.savedCameras.v1';
  static final changes = ValueNotifier<int>(0);
  final FlutterSecureStorage _storage;
  final String key;
  final int maxPairings;
  Future<void> _pending = Future<void>.value();

  Future<List<SavedCamera>> load() async {
    final raw = await _storage.read(key: key);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final cameras = <String, SavedCamera>{};
      for (final item in decoded) {
        final camera = SavedCamera.fromJson(item);
        if (camera != null) cameras[camera.id] = camera;
      }
      return cameras.values.toList();
    } on FormatException {
      return [];
    }
  }

  Future<List<SavedCamera>> _update(void Function(List<SavedCamera>) update) {
    final operation = _pending.then((_) async {
      final cameras = await load();
      update(cameras);
      await _storage.write(
        key: key,
        value: jsonEncode(cameras.map((camera) => camera.toJson()).toList()),
      );
      changes.value++;
      return cameras;
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<List<SavedCamera>> remember(
    String pairingUri, {
    bool isPaired = true,
  }) {
    final credentials = AudioPairingCredentials.tryParse(pairingUri);
    if (credentials == null) {
      throw const FormatException('Invalid pairing link.');
    }
    final camera = SavedCamera(credentials: credentials, isPaired: isPaired);
    return _update((cameras) {
      final index = cameras.indexWhere((entry) => entry.id == camera.id);
      if (index >= 0) {
        if (isPaired && !cameras[index].isPaired) {
          cameras[index] = SavedCamera(
            credentials: credentials,
            name: cameras[index].name,
          );
        }
        return;
      }
      if (cameras.where((entry) => entry.mode == camera.mode).length >=
          maxPairings) {
        throw StateError(
          key == storageKey
              ? DeviceLimits.cameraLimitMessage
              : DeviceLimits.monitorLimitMessage,
        );
      }
      cameras.add(camera);
    });
  }

  Future<List<SavedCamera>> rename(String id, String name) =>
      _update((cameras) {
        final index = cameras.indexWhere((camera) => camera.id == id);
        if (index < 0) return;
        cameras[index] = SavedCamera(
          credentials: cameras[index].credentials,
          isPaired: cameras[index].isPaired,
          name: name.trim().isEmpty ? null : name.trim(),
        );
      });

  Future<List<SavedCamera>> remove(String id) =>
      _update((cameras) => cameras.removeWhere((camera) => camera.id == id));
}
