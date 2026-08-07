import 'package:shared_preferences/shared_preferences.dart';

class MonitorSettings {
  const MonitorSettings({
    this.motionEnabled = true,
    this.soundEnabled = true,
    this.connectionEnabled = true,
    this.sensitivity = 1,
  });

  final bool motionEnabled;
  final bool soundEnabled;
  final bool connectionEnabled;
  final int sensitivity;

  MonitorSettings copyWith({
    bool? motionEnabled,
    bool? soundEnabled,
    bool? connectionEnabled,
    int? sensitivity,
  }) => MonitorSettings(
    motionEnabled: motionEnabled ?? this.motionEnabled,
    soundEnabled: soundEnabled ?? this.soundEnabled,
    connectionEnabled: connectionEnabled ?? this.connectionEnabled,
    sensitivity: sensitivity ?? this.sensitivity,
  );
}

class MonitorSettingsRepository {
  static const _motionKey = 'monitor.motionEnabled';
  static const _soundKey = 'monitor.soundEnabled';
  static const _connectionKey = 'monitor.connectionEnabled';
  static const _sensitivityKey = 'monitor.sensitivity';

  Future<MonitorSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return MonitorSettings(
      motionEnabled: preferences.getBool(_motionKey) ?? true,
      soundEnabled: preferences.getBool(_soundKey) ?? true,
      connectionEnabled: preferences.getBool(_connectionKey) ?? true,
      sensitivity: (preferences.getInt(_sensitivityKey) ?? 1).clamp(0, 2),
    );
  }

  Future<void> save(MonitorSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setBool(_motionKey, settings.motionEnabled),
      preferences.setBool(_soundKey, settings.soundEnabled),
      preferences.setBool(_connectionKey, settings.connectionEnabled),
      preferences.setInt(_sensitivityKey, settings.sensitivity),
    ]);
  }
}
