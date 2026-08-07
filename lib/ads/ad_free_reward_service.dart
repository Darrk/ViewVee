import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the temporary ad-free entitlement independently of the ad SDK.
class AdFreeRewardStore {
  AdFreeRewardStore(this.preferences, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const preferenceKey = 'ads.rewardAdFreeUntilEpochMs';
  static const rewardDuration = Duration(hours: 24);

  final SharedPreferences preferences;
  final DateTime Function() _now;

  DateTime? get validUntil {
    final milliseconds = preferences.getInt(preferenceKey);
    if (milliseconds == null) return null;
    final now = _now();
    final value = DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: now.isUtc,
    );
    if (!value.isAfter(now)) {
      unawaited(preferences.remove(preferenceKey));
      return null;
    }
    return value;
  }

  bool get isActive => validUntil != null;

  Duration get remaining {
    final until = validUntil;
    return until == null ? Duration.zero : until.difference(_now());
  }

  Future<DateTime> grant() async {
    final until = _now().add(rewardDuration);
    await preferences.setInt(preferenceKey, until.millisecondsSinceEpoch);
    return until;
  }
}

enum RewardedAdResult { earned, unavailable, failed }

/// Loads and presents the opt-in fullscreen rewarded ad.
class ViewveeRewardedAdService {
  ViewveeRewardedAdService._();

  static final instance = ViewveeRewardedAdService._();

  // Keep Google's sample units until ViewVee receives its own AdMob units.
  static const _androidRewardedId = 'ca-app-pub-3940256099942544/5224354917';
  static const _iosRewardedId = 'ca-app-pub-3940256099942544/1712485313';

  RewardedAd? _ad;
  Future<bool>? _loading;
  bool _mobileAdsInitialized = false;

  String? get _adUnitId {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _androidRewardedId,
      TargetPlatform.iOS => _iosRewardedId,
      _ => null,
    };
  }

  Future<bool> preload() {
    if (_ad != null) return Future.value(true);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<bool> _load() async {
    final adUnitId = _adUnitId;
    if (adUnitId == null) return false;
    try {
      if (!_mobileAdsInitialized) {
        await MobileAds.instance.initialize();
        _mobileAdsInitialized = true;
      }

      final completer = Completer<bool>();
      RewardedAd.load(
        adUnitId: adUnitId,
        request: const AdRequest(nonPersonalizedAds: true),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _ad?.dispose();
            _ad = ad;
            completer.complete(true);
          },
          onAdFailedToLoad: (error) {
            debugPrint('ViewVee rewarded ad failed to load: $error');
            completer.complete(false);
          },
        ),
      );
      return completer.future;
    } catch (error) {
      debugPrint('ViewVee rewarded ads are unavailable: $error');
      return false;
    }
  }

  Future<RewardedAdResult> show() async {
    if (_ad == null && !await preload()) return RewardedAdResult.unavailable;
    final ad = _ad;
    if (ad == null) return RewardedAdResult.unavailable;
    _ad = null;

    final completer = Completer<RewardedAdResult>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (shownAd) {
        shownAd.dispose();
        if (!completer.isCompleted) {
          completer.complete(
            earned ? RewardedAdResult.earned : RewardedAdResult.failed,
          );
        }
        unawaited(preload());
      },
      onAdFailedToShowFullScreenContent: (shownAd, error) {
        debugPrint('ViewVee rewarded ad failed to show: $error');
        shownAd.dispose();
        if (!completer.isCompleted) {
          completer.complete(RewardedAdResult.failed);
        }
        unawaited(preload());
      },
    );
    ad.show(
      onUserEarnedReward: (_, _) {
        earned = true;
      },
    );
    return completer.future;
  }

  void dispose() {
    _ad?.dispose();
    _ad = null;
  }
}
