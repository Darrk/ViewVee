import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../monitor/saved_camera_repository.dart';
import '../monitor/device_limits.dart';
import 'audio_pairing.dart';

/// Host-side invitations survive stopping capture and process restarts. Each
/// monitor keeps its own secret; fresh transport nonces are still negotiated.
class CameraPairingRepository {
  CameraPairingRepository({FlutterSecureStorage? storage})
    : _repository = SavedCameraRepository(
        storage: storage,
        key: storageKey,
        maxPairings: DeviceLimits.monitors,
      );

  static const storageKey = 'camera.pairings.v1';
  final SavedCameraRepository _repository;

  Future<List<AudioPairingCredentials>> load(AudioPairingMode mode) async =>
      (await _repository.load())
          .where((entry) => entry.mode == mode)
          .map((entry) => entry.credentials)
          .toList();

  Future<List<SavedCamera>> loadDevices() async =>
      (await _repository.load()).where((entry) => entry.isPaired).toList();

  Future<void> markPaired(String pairingUri) async {
    await _repository.remember(pairingUri);
  }

  Future<void> remember(String pairingUri) async {
    await _repository.remember(pairingUri, isPaired: false);
  }
}
