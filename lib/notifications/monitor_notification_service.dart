import 'dart:io';
import 'package:flutter/services.dart';
import '../auth/auth_repository.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../localization/viewvee_localizations.dart';

enum MonitorNotificationType { motion, sound, connectionLost }

class MonitorNotificationService {
  MonitorNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  bool _available = true;

  Future<void> initialize() async {
    if (_initialized || !_available || kIsWeb) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_launcher_foreground'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _initialized = true;
    } catch (error) {
      _available = false;
      debugPrint('ViewVee notifications unavailable: $error');
    }
  }

  Future<bool> requestPermission() async {
    await initialize();
    if (!_available || kIsWeb) return false;
    if (Platform.isAndroid) return Permission.notification.request().isGranted;
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return true;
  }

  Future<void> show(
    MonitorNotificationType type, {
    WatchMode watchMode = WatchMode.home,
    bool inForeground = true,
  }) async {
    await initialize();
    if (!_available || !_initialized) return;
    final locale =
        ViewVeeLocaleController.instance.locale ??
        PlatformDispatcher.instance.locale;
    final localizations = ViewVeeLocalizations(locale);
    String vv(String source) => localizations.translate(source);
    final (id, title, body) = switch (type) {
      MonitorNotificationType.motion => (
        1001,
        vv('Detekce pohybu'),
        vv('Detekce pohybu'),
      ),
      MonitorNotificationType.sound => (
        1002,
        vv(watchMode == WatchMode.baby ? 'Dítě vzhůru' : 'Detekován hluk'),
        vv('Kamera zaznamenala zvýšenou hladinu zvuku.'),
      ),
      MonitorNotificationType.connectionLost => (
        1003,
        vv('Ztráta spojení'),
        vv('Ztráta spojení'),
      ),
    };
    if (type == MonitorNotificationType.sound &&
        inForeground &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      await HapticFeedback.vibrate();
    }
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'viewvee_alerts_v2',
          vv('Chytré notifikace'),
          channelDescription: vv('Detekce zvuku'),
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 300, 150, 300]),
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
      ),
    );
  }
}
