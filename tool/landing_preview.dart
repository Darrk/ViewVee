import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/screens/home_screen.dart';
import 'package:viewvee/screens/setup_screen.dart';
import 'package:viewvee/theme/viewvee_theme.dart';
import 'package:viewvee/widgets/viewvee_app_drawer.dart';

void main() {
  final localeCode = Uri.base.queryParameters['locale'] ?? 'en';
  final screen = Uri.base.queryParameters['screen'] ?? 'setup';
  final darkMode = Uri.base.queryParameters['theme'] == 'dark';
  final locale = localeCode == 'zh_Hant'
      ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
      : Locale(localeCode);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildViewveeTheme(),
      darkTheme: buildViewveeDarkTheme(),
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      locale: locale,
      supportedLocales: ViewveeLocalizations.supportedLocales,
      localizationsDelegates: const [
        ViewveeLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: switch (screen) {
        'menu' => const _DrawerPreview(),
        'role' => HomeScreen(
          watchMode: WatchMode.baby,
          isGuest: false,
          isPremium: false,
          onWatchModeChanged: (_) async {},
          themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
          onThemeModeChanged: (_) async {},
          onPasswordReset: (_) async {},
          onSignOut: () {},
        ),
        _ => SetupScreen(onSelected: (_) {}),
      },
    ),
  );
}

class _DrawerPreview extends StatefulWidget {
  const _DrawerPreview();

  @override
  State<_DrawerPreview> createState() => _DrawerPreviewState();
}

class _DrawerPreviewState extends State<_DrawerPreview> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scaffoldKey.currentState?.openDrawer(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: _scaffoldKey,
    appBar: AppBar(title: const Text('ViewVee')),
    drawer: ViewveeAppDrawer(
      watchMode: WatchMode.baby,
      activeDestination: ViewveeDrawerDestination.monitor,
      isPremium: false,
      profileName: 'Jana Nováková',
      profileEmail: 'jana@example.cz',
      onOpenMonitor: () {},
      onOpenDevices: () {},
      onOpenRecordings: () {},
      onOpenAccount: () {},
      onOpenSubscription: () {},
      onOpenPreferences: () {},
      onOpenSupport: () {},
      onOpenAbout: () {},
      onSignOut: () {},
    ),
    body: const SizedBox.expand(),
  );
}
