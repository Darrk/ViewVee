import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ad_free_reward_service.dart';

/// An interstitial is offered at the natural break between free sessions.
/// A missing ad does not prevent the user from starting the next free hour.
class SessionBreakAd {
  Future<void> show() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    if (AdFreeRewardStore(preferences).isActive) return;
    InterstitialAd? loaded;
    var accepting = true;
    try {
      await MobileAds.instance.initialize().timeout(
        const Duration(seconds: 10),
      );
      final ready = Completer<InterstitialAd?>();
      // Same test-unit policy as the existing rewarded ads. Production builds
      // supply the app's real AdMob unit through dart-define.
      final unit = defaultTargetPlatform == TargetPlatform.iOS
          ? const String.fromEnvironment(
              'VIEWVEE_IOS_INTERSTITIAL_ID',
              defaultValue: 'ca-app-pub-3940256099942544/4411468910',
            )
          : const String.fromEnvironment(
              'VIEWVEE_ANDROID_INTERSTITIAL_ID',
              defaultValue: 'ca-app-pub-3940256099942544/1033173712',
            );
      await InterstitialAd.load(
        adUnitId: unit,
        request: const AdRequest(nonPersonalizedAds: true),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            if (!accepting) {
              ad.dispose();
              return;
            }
            ready.complete(ad);
          },
          onAdFailedToLoad: (_) {
            if (!ready.isCompleted) ready.complete(null);
          },
        ),
      );
      loaded = await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      accepting = false;
      if (loaded == null) return;
      final dismissed = Completer<void>();
      loaded.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (_) {
          if (!dismissed.isCompleted) dismissed.complete();
        },
        onAdFailedToShowFullScreenContent: (_, _) {
          if (!dismissed.isCompleted) dismissed.complete();
        },
      );
      await loaded.show();
      await dismissed.future;
    } catch (error) {
      debugPrint('ViewVee session break ad unavailable: $error');
    } finally {
      accepting = false;
      await loaded?.dispose();
    }
  }
}
