import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/monitor/free_session_limit.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';

void main() {
  testWidgets(
    'free hour accumulates across disconnects and requires explicit reset',
    (tester) async {
      var breaks = 0;
      final limit = FreeSessionLimit(
        onExpired: () => breaks++,
        now: tester.binding.clock.now,
      );
      addTearDown(limit.dispose);
      limit.update(running: true);
      await tester.pump(const Duration(minutes: 40));
      limit.update(running: false);
      await tester.pump(const Duration(hours: 2));
      expect(breaks, 0);
      limit.update(running: true);
      await tester.pump(const Duration(minutes: 20));
      expect(breaks, 1);
      expect(limit.expired, isTrue);
      limit.update(running: true);
      await tester.pump(const Duration(hours: 1));
      expect(breaks, 1);
      limit.reset();
      limit.update(running: true);
      await tester.pump(const Duration(hours: 1));
      expect(breaks, 2);
    },
  );

  testWidgets('premium cancels the free deadline', (tester) async {
    var breaks = 0;
    final limit = FreeSessionLimit(
      onExpired: () => breaks++,
      now: tester.binding.clock.now,
    );
    addTearDown(limit.dispose);
    limit.update(running: true);
    await tester.pump(const Duration(minutes: 59));
    limit.update(running: false);
    await tester.pump(const Duration(hours: 3));
    expect(breaks, 0);
  });

  test(
    'free services reject paid operations before opening hardware or signaling',
    () async {
      final wifi = AudioMonitorService(mode: AudioConnectionMode.wifi);
      await expectLater(wifi.createMonitorPairing(), throwsStateError);
      await expectLater(wifi.setVideoQuality(isHd: true), throwsStateError);
      await expectLater(wifi.setTalkbackEnabled(true), throwsStateError);
      await expectLater(
        wifi.startRecording('/tmp/not-created.mp4'),
        throwsStateError,
      );
      final internet = AudioMonitorService();
      await expectLater(internet.startTransmitter(), throwsStateError);
      await expectLater(
        internet.joinAsReceiver('saved-link'),
        throwsStateError,
      );
      wifi.setPremiumEnabled(true);
      await wifi.setVideoQuality(
        isHd: true,
      ); // No capture yet, but no tariff rejection.
      wifi.setPremiumEnabled(false);
      await expectLater(wifi.setVideoQuality(isHd: true), throwsStateError);
    },
  );
}
