import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';
import 'package:viewvee/notifications/monitor_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ViewVeeLocaleController.instance.setLanguage('cs');
  });

  for (final mode in WatchMode.values) {
    test('sound alert labels and vibration for ${mode.name}', () async {
      final plugin = _Notifications();
      final service = MonitorNotificationService(plugin: plugin);
      await service.show(
        MonitorNotificationType.sound,
        watchMode: mode,
        inForeground: false,
      );
      expect(
        plugin.title,
        mode == WatchMode.baby ? 'Dítě vzhůru' : 'Detekován hluk',
      );
      expect(plugin.body, 'Kamera zaznamenala zvýšenou hladinu zvuku.');
      expect(plugin.details!.android!.enableVibration, isTrue);
      expect(plugin.details!.android!.vibrationPattern, [0, 300, 150, 300]);
      expect(plugin.details!.iOS!.presentSound, isTrue);
      expect(plugin.details!.iOS!.presentBanner, isTrue);
    });
  }
}

class _Notifications extends Fake implements FlutterLocalNotificationsPlugin {
  String? title;
  String? body;
  NotificationDetails? details;
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    this.title = title;
    this.body = body;
    details = notificationDetails;
  }
}
