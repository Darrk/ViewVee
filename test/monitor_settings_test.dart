import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/monitor/monitor_settings.dart';

void main() {
  test(
    'automatic reconnection defaults on for existing installations',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await MonitorSettingsRepository().load();
      expect(settings.autoReconnectEnabled, isTrue);
      expect(
        settings.copyWith(autoReconnectEnabled: false).autoReconnectEnabled,
        isFalse,
      );
    },
  );
  test('monitor settings persist all notification choices', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = MonitorSettingsRepository();
    const expected = MonitorSettings(
      motionEnabled: false,
      soundEnabled: true,
      connectionEnabled: false,
      autoReconnectEnabled: false,
      sensitivity: 2,
    );

    await repository.save(expected);
    final restored = await repository.load();

    expect(restored.motionEnabled, expected.motionEnabled);
    expect(restored.soundEnabled, expected.soundEnabled);
    expect(restored.connectionEnabled, expected.connectionEnabled);
    expect(restored.sensitivity, expected.sensitivity);
    expect(restored.autoReconnectEnabled, isFalse);
  });
}
