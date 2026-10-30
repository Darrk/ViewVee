/// Pairing limits apply separately to each connection mode.
abstract final class DeviceLimits {
  static const cameras = 2;
  static const monitors = 5;
  static const cameraLimitMessage = 'Lze připojit nejvýše 2 kamery.';
  static const monitorLimitMessage =
      'Ke kameře lze připojit nejvýše 5 monitorů.';
}
