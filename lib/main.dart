import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/auth_repository.dart';
import 'config.dart';
import 'screens/auth_screen.dart';
import 'screens/account_menu_screen.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'theme/viewvee_theme.dart';
import 'widgets/viewvee_app_drawer.dart';
import 'widgets/viewvee_logo.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ViewVeeApp());
}

class ViewVeeApp extends StatefulWidget {
  const ViewVeeApp({
    super.key,
    this.authRepository,
    this.previewAuthenticated = false,
  });

  final AuthRepository? authRepository;
  final bool previewAuthenticated;

  @override
  State<ViewVeeApp> createState() => _ViewVeeAppState();
}

class _ViewVeeAppState extends State<ViewVeeApp> {
  static const _minimumIntroDuration = Duration(milliseconds: 3000);
  static const _themeModeKey = 'preferences.themeMode';

  late final AuthRepository? _authRepository;
  late Future<AppSession> _session;
  ThemeMode _themeMode = ThemeMode.system;
  final _localeController = ViewVeeLocaleController.instance;

  @override
  void initState() {
    super.initState();
    _authRepository = widget.previewAuthenticated
        ? null
        : widget.authRepository ?? AuthRepository();
    _session = _restoreInitialSession();
    _loadThemeMode();
    _localeController.addListener(_localeChanged);
    _localeController.load();
  }

  void _localeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _localeController.removeListener(_localeChanged);
    super.dispose();
  }

  Future<void> _loadThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    final savedMode = preferences.getString(_themeModeKey);
    final mode = ThemeMode.values.where((value) => value.name == savedMode);
    if (mounted && mode.isNotEmpty) setState(() => _themeMode = mode.first);
  }

  Future<void> _changeThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeModeKey, mode.name);
  }

  Future<AppSession> _restoreInitialSession() async {
    if (widget.previewAuthenticated) {
      final preferences = await SharedPreferences.getInstance();
      return AppSession(
        isSignedIn: true,
        isGuest: false,
        watchMode: null,
        isPremium:
            !Config.enablePremiumFeatures ||
            (preferences.getBool(AuthRepository.premiumUnlockedKey) ?? false),
      );
    }
    if (kDebugMode) {
      await Future<void>.delayed(_minimumIntroDuration);
      return const AppSession(isSignedIn: false, isGuest: false);
    }
    final results = await Future.wait([
      _authRepository!.restoreSession().timeout(
        const Duration(seconds: 4),
        onTimeout: () => const AppSession(isSignedIn: false, isGuest: false),
      ),
      Future<void>.delayed(_minimumIntroDuration),
    ]);
    return results.first as AppSession;
  }

  void _refreshSession() {
    setState(() {
      _session = _authRepository!.restoreSession();
    });
  }

  Future<void> _selectWatchMode(WatchMode mode) async {
    if (_authRepository == null) {
      final preferences = await SharedPreferences.getInstance();
      setState(() {
        _session = Future.value(
          AppSession(
            isSignedIn: true,
            isGuest: false,
            watchMode: mode,
            isPremium:
                !Config.enablePremiumFeatures ||
                (preferences.getBool(AuthRepository.premiumUnlockedKey) ??
                    false),
          ),
        );
      });
      return;
    }
    await _authRepository.saveWatchMode(mode);
    _refreshSession();
  }

  Future<void> _resetPassword(String email) async {
    final repository = _authRepository ?? AuthRepository();
    await repository.forgotPassword(email);
  }

  void _openAccountMenu(
    BuildContext context,
    AppSession session,
    ViewVeeDrawerDestination destination,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountMenuScreen(
          isGuest: session.isGuest,
          isPremium: session.isPremium,
          accountId: session.accountId,
          watchMode: session.watchMode,
          themeMode: _themeMode,
          initialDestination: destination,
          onWatchModeChanged: _selectWatchMode,
          onThemeModeChanged: _changeThemeMode,
          onPasswordReset: _resetPassword,
          onAddDevice: (_) async {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: VvText('Nejprve vyberte, co chcete hlídat.'),
              ),
            );
          },
          onSignOut: () async {
            if (_authRepository == null) return;
            await _authRepository.signOut();
            _refreshSession();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ViewVee',
      debugShowCheckedModeBanner: false,
      theme: buildViewVeeTheme(),
      darkTheme: buildViewVeeDarkTheme(),
      themeMode: _themeMode,
      locale: _localeController.locale,
      supportedLocales: ViewVeeLocalizations.supportedLocales,
      localizationsDelegates: const [
        ViewVeeLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: FutureBuilder<AppSession>(
        future: _session,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const _SplashScreen();

          final session = snapshot.data!;
          if (!session.isSignedIn) {
            return AuthScreen(
              authRepository: _authRepository!,
              onAuthenticated: _refreshSession,
            );
          }
          if (session.watchMode == null) {
            return SetupScreen(
              drawer: ViewVeeAppDrawer(
                watchMode: null,
                activeDestination: ViewVeeDrawerDestination.monitor,
                isPremium: session.isPremium,
                onOpenMonitor: () {},
                onOpenDevices: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.devices,
                ),
                onOpenRecordings: () => _openAccountMenu(
                  context,
                  session,
                  session.isPremium
                      ? ViewVeeDrawerDestination.recordings
                      : ViewVeeDrawerDestination.subscription,
                ),
                onOpenAccount: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.account,
                ),
                onOpenSubscription: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.subscription,
                ),
                onOpenPreferences: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.preferences,
                ),
                onOpenSupport: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.support,
                ),
                onOpenAbout: () => _openAccountMenu(
                  context,
                  session,
                  ViewVeeDrawerDestination.about,
                ),
                onSignOut: () async {
                  if (_authRepository == null) return;
                  await _authRepository.signOut();
                  _refreshSession();
                },
              ),
              onSelected: _selectWatchMode,
            );
          }
          return HomeScreen(
            watchMode: session.watchMode!,
            isGuest: session.isGuest,
            isPremium: session.isPremium,
            onWatchModeChanged: _selectWatchMode,
            themeMode: _themeMode,
            onThemeModeChanged: _changeThemeMode,
            onPasswordReset: _resetPassword,
            onSignOut: () async {
              if (_authRepository == null) return;
              await _authRepository.signOut();
              _refreshSession();
            },
          );
        },
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            AnimatedViewVeeLogo(),
            SizedBox(height: 28),
            _LoadingDots(),
          ],
        ),
      ),
    );
  }
}

class _LoadingDots extends StatefulWidget {
  const _LoadingDots();

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const colors = [
      ViewVeeColors.teal,
      ViewVeeColors.blue,
      ViewVeeColors.violet,
    ];
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(colors.length, (index) {
          final phase = (_controller.value - index * 0.16) % 1.0;
          final scale = 0.65 + 0.35 * (1 - (phase * 2 - 1).abs());
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Transform.scale(
              scale: scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors[index],
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(width: 8, height: 8),
              ),
            ),
          );
        }),
      ),
    );
  }
}
