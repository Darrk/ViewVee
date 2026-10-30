import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Refreshes UMP once per launch and fails closed when consent is unavailable.
class AdConsentService extends ChangeNotifier {
  static final instance = AdConsentService();
  Future<void>? _update;
  bool privacyOptionsRequired = false;
  int generation = 0;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<bool> canRequestAds() async {
    if (!_supported) return false;
    _update ??= _refresh();
    await _update;
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      return false;
    }
  }

  Future<void> _refresh() async {
    try {
      final updated = Completer<bool>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () {
          if (!updated.isCompleted) updated.complete(true);
        },
        (_) {
          if (!updated.isCompleted) updated.complete(false);
        },
      );
      if (await updated.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      )) {
        final shown = Completer<void>();
        await ConsentForm.loadAndShowConsentFormIfRequired((_) {
          if (!shown.isCompleted) shown.complete();
        });
        await shown.future;
      }
      privacyOptionsRequired =
          await ConsentInformation.instance
              .getPrivacyOptionsRequirementStatus() ==
          PrivacyOptionsRequirementStatus.required;
      notifyListeners();
    } catch (_) {
      // Ads remain unavailable until UMP confirms that they can be requested.
    }
  }

  Future<void> showPrivacyOptions() async {
    if (!_supported) return;
    final done = Completer<void>();
    await ConsentForm.showPrivacyOptionsForm((error) {
      if (error == null) {
        generation++;
        notifyListeners();
      }
      done.complete();
    });
    await done.future;
  }
}
