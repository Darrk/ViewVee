import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_pairing.dart';
import 'package:viewvee/audio/audio_pairing_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'camera identity survives repository and app recreation in both modes',
    () async {
      for (final mode in AudioPairingMode.values) {
        final first = await AudioPairingRepository().cameraCredentials(mode);
        final restarted = await AudioPairingRepository().cameraCredentials(
          mode,
        );
        expect(restarted.toUriString(), first.toUriString());
        expect(restarted.mode, mode);
      }
    },
  );

  test(
    'saved monitor link survives restart and stays separate per mode',
    () async {
      final wifi = AudioPairingCredentials.generate(
        mode: AudioPairingMode.wifi,
      );
      final internet = AudioPairingCredentials.generate();
      final repository = AudioPairingRepository();
      await repository.rememberMonitor(wifi.toUriString());
      await repository.rememberMonitor(internet.toUriString());
      final restarted = AudioPairingRepository();
      expect(
        await restarted.monitorPairing(AudioPairingMode.wifi),
        wifi.toUriString(),
      );
      expect(
        await restarted.monitorPairing(AudioPairingMode.internet),
        internet.toUriString(),
      );
    },
  );

  test(
    'clearing pairings revokes the old camera identity and monitor links',
    () async {
      final repository = AudioPairingRepository();
      final first = await repository.cameraCredentials(
        AudioPairingMode.internet,
      );
      await repository.rememberMonitor(first.toUriString());
      await repository.clear();
      expect(
        await repository.monitorPairing(AudioPairingMode.internet),
        isNull,
      );
      final next = await repository.cameraCredentials(
        AudioPairingMode.internet,
      );
      expect(next.secret, isNot(first.secret));
      expect(next.sessionId, isNot(first.sessionId));
    },
  );

  test('corrupt or mismatched stored credentials are replaced', () async {
    FlutterSecureStorage.setMockInitialValues({
      'viewvee.camera.wifi': AudioPairingCredentials.generate().toUriString(),
      'viewvee.camera.internet': 'invalid',
      'viewvee.monitor.internet': 'invalid',
    });
    final repository = AudioPairingRepository();
    expect(
      (await repository.cameraCredentials(AudioPairingMode.wifi)).mode,
      AudioPairingMode.wifi,
    );
    expect(
      (await repository.cameraCredentials(AudioPairingMode.internet)).sessionId,
      isNotNull,
    );
    expect(await repository.monitorPairing(AudioPairingMode.internet), isNull);
    await expectLater(
      repository.rememberMonitor('invalid'),
      throwsFormatException,
    );
  });
}
