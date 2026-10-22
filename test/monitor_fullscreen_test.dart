import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/screens/home_screen.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/theme/viewvee_theme.dart';

void main() {
  testWidgets(
    'monitor preview enters fullscreen, rotates, and exits without leaving the monitor',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('viewvee/audio_monitor');
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildViewVeeTheme(),
          home: HomeScreen(
            watchMode: WatchMode.baby,
            isGuest: true,
            isPremium: false,
            themeMode: ThemeMode.light,
            onWatchModeChanged: (_) async {},
            onThemeModeChanged: (_) async {},
            onPasswordReset: (_) async {},
            onSignOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('monitorRole')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('continueRole')));
      await tester.tap(find.byKey(const Key('continueRole')));
      await tester.pumpAndSettle();
      final enter = find.byKey(const Key('enterMonitorFullscreen'));
      final exit = find.byKey(const Key('exitMonitorFullscreen'));
      expect(enter, findsOneWidget);
      expect(find.byKey(const Key('monitorVideoQuality')), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Stack),
          matching: find.byKey(const Key('monitorVideoQuality')),
        ),
        findsOneWidget,
      );
      // The quality menu must open even before a camera is paired.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('monitorVideoQuality')),
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
      );
      await tester.pumpAndSettle();
      final hdOption = find.widgetWithText(CheckedPopupMenuItem<bool>, 'HD');
      expect(hdOption, findsOneWidget);
      expect(
        find.descendant(
          of: hdOption,
          matching: find.byIcon(Icons.lock_outline_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(hdOption);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('openPremiumFromHd')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('startRecordingButton')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Stack),
          matching: find.byKey(const Key('startRecordingButton')),
        ),
        findsOneWidget,
      );
      await tester.tap(enter);
      await tester.pumpAndSettle();
      expect(exit, findsOneWidget);
      expect(find.byKey(const Key('monitorVideoQuality')), findsOneWidget);
      expect(find.byKey(const Key('startRecordingButton')), findsOneWidget);
      expect(find.byKey(const Key('homeMenuButton')), findsNothing);
      expect(find.byKey(const Key('cameraListToggle')), findsNothing);
      await tester.binding.setSurfaceSize(const Size(932, 430));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(exit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('homeMenuButton')), findsOneWidget);
      expect(find.byKey(const Key('cameraListToggle')), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(430, 932));
      await tester.pumpAndSettle();
      await tester.ensureVisible(enter);
      await tester.tap(enter);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exit, findsNothing);
      expect(enter, findsOneWidget);
      expect(find.byKey(const Key('monitorRole')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
