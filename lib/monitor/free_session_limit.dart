import 'dart:async';

/// Counts connected time across reconnects and camera changes. Only an explicit
/// new free session resets the allowance; a temporary disconnect never does.
class FreeSessionLimit {
  FreeSessionLimit({required this.onExpired, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  static const allowance = Duration(hours: 1);
  final void Function() onExpired;
  final DateTime Function() _now;
  Duration _used = Duration.zero;
  DateTime? _started;
  Timer? _timer;
  bool expired = false;

  void update({required bool running}) {
    final started = _started;
    if (started != null) _used += _now().difference(started);
    _started = null;
    _timer?.cancel();
    if (expired || !running) return;
    final remaining = allowance - _used;
    if (remaining <= Duration.zero) {
      _expire();
      return;
    }
    _started = _now();
    _timer = Timer(remaining, _expire);
  }

  void _expire() {
    if (expired) return;
    expired = true;
    _started = null;
    _timer?.cancel();
    onExpired();
  }

  void reset() {
    dispose();
    _used = Duration.zero;
    expired = false;
  }

  void dispose() {
    _timer?.cancel();
    _started = null;
  }
}
