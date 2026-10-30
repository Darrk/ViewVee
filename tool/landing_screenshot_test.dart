import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/screens/home_screen.dart';
import 'package:viewvee/screens/setup_screen.dart';
import 'package:viewvee/theme/viewvee_theme.dart';

void main() {
  testWidgets('renders localized dark role selection screenshots', (
    tester,
  ) async {
    const audioMonitorChannel = MethodChannel('viewvee/audio_monitor');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      audioMonitorChannel,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioMonitorChannel,
        null,
      ),
    );
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(const {});
    await tester.runAsync(() async {
      await _loadFont('Avenir Next', '/System/Library/Fonts/SFNS.ttf');
      await _loadFont(
        'Screenshot Arabic',
        '/System/Library/Fonts/SFArabic.ttf',
      );
      await _loadFont(
        'Screenshot CJK',
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      );
      await _loadFont(
        'Screenshot Korean',
        '/System/Library/Fonts/AppleSDGothicNeo.ttc',
      );
      await _loadFont(
        'Screenshot Thai',
        '/System/Library/Fonts/ThonburiUI.ttc',
      );
      await _loadFont(
        'MaterialIcons',
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      );
      await _loadFont(
        'packages/font_awesome_flutter/FontAwesomeSolid',
        'build/unit_test_assets/packages/font_awesome_flutter/lib/fonts/'
            'Font-Awesome-7-Free-Solid-900.otf',
      );
    });

    tester.view.physicalSize = const Size(470, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lightTheme = _withScreenshotFontFallback(buildViewVeeTheme());
    final darkTheme = _withScreenshotFontFallback(buildViewVeeDarkTheme());

    const screenshots = <({Locale locale, String fileName})>[
      (locale: Locale('ar'), fileName: 'ar'),
      (locale: Locale('cs'), fileName: 'cs'),
      (locale: Locale('da'), fileName: 'da'),
      (locale: Locale('de'), fileName: 'de'),
      (locale: Locale('en'), fileName: 'en'),
      (locale: Locale('es'), fileName: 'es'),
      (locale: Locale('fi'), fileName: 'fi'),
      (locale: Locale('fr'), fileName: 'fr'),
      (locale: Locale('hr'), fileName: 'hr'),
      (locale: Locale('hu'), fileName: 'hu'),
      (locale: Locale('id'), fileName: 'id'),
      (locale: Locale('it'), fileName: 'it'),
      (locale: Locale('ja'), fileName: 'ja'),
      (locale: Locale('ko'), fileName: 'ko'),
      (locale: Locale('nb'), fileName: 'nb'),
      (locale: Locale('nl'), fileName: 'nl'),
      (locale: Locale('pl'), fileName: 'pl'),
      (locale: Locale('pt'), fileName: 'pt'),
      (locale: Locale('ro'), fileName: 'ro'),
      (locale: Locale('ru'), fileName: 'ru'),
      (locale: Locale('sk'), fileName: 'sk'),
      (locale: Locale('sv'), fileName: 'sv'),
      (locale: Locale('th'), fileName: 'th'),
      (locale: Locale('tr'), fileName: 'tr'),
      (locale: Locale('uk'), fileName: 'uk'),
      (locale: Locale('vi'), fileName: 'vi'),
      (locale: Locale('zh'), fileName: 'zh'),
      (
        locale: Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        fileName: 'zh_Hant',
      ),
    ];

    for (final screenshot in screenshots) {
      const setupBoundaryKey = Key('setupScreenshotBoundary');
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey('setup-${screenshot.fileName}'),
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: ThemeMode.light,
          locale: screenshot.locale,
          supportedLocales: ViewVeeLocalizations.supportedLocales,
          localizationsDelegates: const [
            ViewVeeLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: RepaintBoundary(
            key: setupBoundaryKey,
            child: SetupScreen(onSelected: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/branding/viewvee_icon_foreground.png'),
          tester.element(find.byKey(setupBoundaryKey)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byKey(const Key('modeBaby')), findsOneWidget);
      expect(find.byKey(const Key('modePet')), findsOneWidget);
      expect(find.byKey(const Key('modeHome')), findsOneWidget);
      await expectLater(
        find.byKey(setupBoundaryKey),
        matchesGoldenFile(
          '../api/web/images/app-setup-${screenshot.fileName}.png',
        ),
      );

      const boundaryKey = Key('screenshotBoundary');
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(screenshot.fileName),
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
          locale: screenshot.locale,
          supportedLocales: ViewVeeLocalizations.supportedLocales,
          localizationsDelegates: const [
            ViewVeeLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: RepaintBoundary(
            key: boundaryKey,
            child: HomeScreen(
              watchMode: WatchMode.baby,
              isGuest: false,
              isPremium: false,
              onWatchModeChanged: (_) async {},
              themeMode: ThemeMode.dark,
              onThemeModeChanged: (_) async {},
              onPasswordReset: (_) async {},
              onSignOut: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/branding/viewvee_icon_dark.png'),
          tester.element(find.byKey(boundaryKey)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      await expectLater(
        find.byKey(boundaryKey),
        matchesGoldenFile(
          '../api/web/images/app-real-role-${screenshot.fileName}-dark.png',
        ),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

ThemeData _withScreenshotFontFallback(ThemeData theme) {
  const families = <String>[
    'Screenshot Arabic',
    'Screenshot CJK',
    'Screenshot Korean',
    'Screenshot Thai',
  ];
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: families),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamilyFallback: families,
    ),
  );
}

Future<void> _loadFont(String family, String path) async {
  final fontBytes = await File(path).readAsBytes();
  await (FontLoader(family)..addFont(
        Future.value(ByteData.sublistView(Uint8List.fromList(fontBytes))),
      ))
      .load();
}
