import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/ads/ad_free_reward_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdFreeRewardStore', () {
    test('grants exactly 24 hours and persists the expiry', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.utc(2026, 8, 6, 10, 30);
      final store = AdFreeRewardStore(preferences, now: () => now);

      final until = await store.grant();

      expect(until, now.add(const Duration(hours: 24)));
      expect(store.isActive, isTrue);
      expect(store.remaining, const Duration(hours: 24));
      expect(
        preferences.getInt(AdFreeRewardStore.preferenceKey),
        until.millisecondsSinceEpoch,
      );
    });

    test('expired reward is ignored and removed', () async {
      final now = DateTime.utc(2026, 8, 6, 10, 30);
      SharedPreferences.setMockInitialValues({
        AdFreeRewardStore.preferenceKey: now
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
      });
      final preferences = await SharedPreferences.getInstance();
      final store = AdFreeRewardStore(preferences, now: () => now);

      expect(store.isActive, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(preferences.containsKey(AdFreeRewardStore.preferenceKey), isFalse);
    });

    test('restores an active reward after app restart', () async {
      final now = DateTime.utc(2026, 8, 6, 10, 30);
      final until = now.add(const Duration(hours: 3, minutes: 15));
      SharedPreferences.setMockInitialValues({
        AdFreeRewardStore.preferenceKey: until.millisecondsSinceEpoch,
      });
      final preferences = await SharedPreferences.getInstance();

      final restored = AdFreeRewardStore(preferences, now: () => now);

      expect(restored.validUntil, until);
      expect(restored.remaining, const Duration(hours: 3, minutes: 15));
    });
  });
}
