import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/audio/camera_pairing_repository.dart';
import 'package:viewvee/monitor/saved_camera_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'only completed monitor pairings appear as devices and stay paired after reuse',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final repository = CameraPairingRepository();
      final link = AudioPairingCredentials.generate().toUriString();
      await repository.remember(link);
      expect(await repository.loadDevices(), isEmpty);
      await repository.markPaired(link);
      await repository.remember(link);
      expect(
        (await CameraPairingRepository().loadDevices()).single.pairingUri,
        link,
      );
    },
  );

  test(
    'camera invitations survive restart, preserve secrets, and separate modes and roles',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final repository = CameraPairingRepository();
      final wifi = AudioPairingCredentials.generate(
        mode: AudioPairingMode.wifi,
      ).toUriString();
      final internet = AudioPairingCredentials.generate().toUriString();
      await Future.wait([
        repository.remember(wifi),
        repository.remember(internet),
      ]);
      await repository.remember(wifi);
      final restored = CameraPairingRepository();
      expect(
        (await restored.load(
          AudioPairingMode.wifi,
        )).map((entry) => entry.toUriString()),
        [wifi],
      );
      expect(
        (await restored.load(
          AudioPairingMode.internet,
        )).map((entry) => entry.toUriString()),
        [internet],
      );
      expect(await SavedCameraRepository().load(), isEmpty);
      await SavedCameraRepository().remember(wifi);
      final monitorCamera = (await SavedCameraRepository().load()).single;
      await SavedCameraRepository().remove(monitorCamera.id);
      expect(await restored.load(AudioPairingMode.wifi), hasLength(1));
    },
  );
}
