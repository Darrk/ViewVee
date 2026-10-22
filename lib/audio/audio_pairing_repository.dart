import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'audio_pairing.dart';

/// Pairing links contain a secret; keep them out of ordinary preferences.
class AudioPairingRepository {
  AudioPairingRepository({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _cameraKey(AudioPairingMode mode) => 'viewvee.camera.${mode.name}';
  String _monitorKey(AudioPairingMode mode) => 'viewvee.monitor.${mode.name}';

  Future<AudioPairingCredentials> cameraCredentials(
    AudioPairingMode mode,
  ) async {
    final saved = await _storage.read(key: _cameraKey(mode));
    final existing = saved == null
        ? null
        : AudioPairingCredentials.tryParse(saved, expectedMode: mode);
    if (existing != null) return existing;
    final credentials = AudioPairingCredentials.generate(mode: mode);
    await _storage.write(
      key: _cameraKey(mode),
      value: credentials.toUriString(),
    );
    return credentials;
  }

  Future<void> rememberMonitor(String pairingValue) async {
    final credentials = AudioPairingCredentials.tryParse(pairingValue);
    if (credentials == null) {
      throw const FormatException('Invalid pairing link.');
    }
    await _storage.write(
      key: _monitorKey(credentials.mode),
      value: credentials.toUriString(),
    );
  }

  Future<String?> monitorPairing(AudioPairingMode mode) async {
    final saved = await _storage.read(key: _monitorKey(mode));
    return saved != null &&
            AudioPairingCredentials.tryParse(saved, expectedMode: mode) != null
        ? saved
        : null;
  }

  Future<void> clear() async {
    for (final mode in AudioPairingMode.values) {
      await _storage.delete(key: _cameraKey(mode));
      await _storage.delete(key: _monitorKey(mode));
    }
  }
}
