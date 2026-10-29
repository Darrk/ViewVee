import 'package:flutter/foundation.dart';

/// A failed camera or connection cleanup must not prevent the remaining steps.
Future<void> runPremiumCleanup(List<Future<void> Function()> actions) async {
  for (final action in actions) {
    try {
      await action();
    } catch (error) {
      debugPrint('ViewVee Premium cleanup failed: $error');
    }
  }
}
