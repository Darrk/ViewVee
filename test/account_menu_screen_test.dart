import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/screens/account_menu_screen.dart';
import 'package:viewvee/theme/viewvee_theme.dart';
import 'package:viewvee/widgets/viewvee_app_drawer.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget buildSubject({
    VoidCallback? onSignOut,
    Future<void> Function(WatchMode mode)? onWatchModeChanged,
    Future<void> Function(ThemeMode mode)? onThemeModeChanged,
    Future<void> Function(String email)? onPasswordReset,
    Future<void> Function(DevicePairingAction action)? onAddDevice,
    ViewveeDrawerDestination initialDestination =
        ViewveeDrawerDestination.account,
    ThemeMode themeMode = ThemeMode.light,
    bool isPremium = true,
    int? accountId,
  }) {
    return MaterialApp(
      theme: buildViewveeTheme(),
      darkTheme: buildViewveeDarkTheme(),
      themeMode: themeMode,
      home: AccountMenuScreen(
        key: UniqueKey(),
        isGuest: false,
        isPremium: isPremium,
        accountId: accountId,
        watchMode: WatchMode.baby,
        themeMode: themeMode,
        initialDestination: initialDestination,
        onWatchModeChanged: onWatchModeChanged ?? (_) async {},
        onThemeModeChanged: onThemeModeChanged ?? (_) async {},
        onPasswordReset: onPasswordReset ?? (_) async {},
        onAddDevice: onAddDevice ?? (_) async {},
        onSignOut: onSignOut ?? () {},
      ),
    );
  }

  testWidgets('profile destination shows only profile content', (tester) async {
    await tester.pumpWidget(buildSubject());

    expect(find.byKey(const Key('profilePage')), findsOneWidget);
    expect(find.text('Doplnit osobní údaje'), findsOneWidget);
    expect(find.text('Můj ViewVee účet'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byKey(const Key('signOutButton')), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountMenuItem')), findsOneWidget);
    expect(find.text('ViewVee Plus'), findsNothing);
    expect(find.byKey(const Key('languageMenuItem')), findsNothing);
    expect(find.text('Jak vám můžeme pomoci?'), findsNothing);
  });

  testWidgets('opens security and sends a password reset link', (tester) async {
    String? resetEmail;
    await tester.pumpWidget(
      buildSubject(onPasswordReset: (email) async => resetEmail = email),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('securityMenuItem')));
    await tester.pumpAndSettle();
    expect(find.text('Zabezpečení'), findsWidgets);
    expect(find.byKey(const Key('securityEmailField')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('securityEmailField')),
      'jana@example.cz',
    );
    await tester.tap(find.byKey(const Key('sendPasswordResetButton')));
    await tester.pumpAndSettle();

    expect(resetEmail, 'jana@example.cz');
    expect(
      find.text('Odkaz pro změnu hesla jsme poslali na jana@example.cz.'),
      findsOneWidget,
    );
  });

  testWidgets('lets the user fill in and persist personal details', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profileMenuItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profilePhoneField')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('profileFirstNameField')),
      'Jana',
    );
    await tester.enterText(
      find.byKey(const Key('profileLastNameField')),
      'Nováková',
    );
    await tester.enterText(
      find.byKey(const Key('profileEmailField')),
      'jana@example.cz',
    );
    await tester.tap(find.byKey(const Key('savePersonalDetailsButton')));
    await tester.pumpAndSettle();

    expect(find.text('Jana Nováková'), findsOneWidget);
    expect(find.text('Upravit osobní údaje'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('profile.firstName'), 'Jana');
    expect(preferences.getString('profile.lastName'), 'Nováková');
    expect(preferences.getString('profile.email'), 'jana@example.cz');
    expect(preferences.getString('profile.phone'), isNull);
  });

  testWidgets('account deletion requires confirmation and opens account page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'profile.firstName': 'Jana',
      'profile.lastName': 'Nováková',
      'profile.email': 'jana@example.cz',
    });
    Uri? openedUri;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildViewveeTheme(),
        home: AccountMenuScreen(
          isGuest: false,
          isPremium: true,
          accountId: 42,
          watchMode: WatchMode.baby,
          themeMode: ThemeMode.light,
          onWatchModeChanged: (_) async {},
          onThemeModeChanged: (_) async {},
          onPasswordReset: (_) async {},
          onAddDevice: (_) async {},
          onSignOut: () {},
          openExternalUrl: (uri) async => openedUri = uri,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('deleteAccountMenuItem')));
    await tester.pumpAndSettle();

    expect(find.text('Smazat účet?'), findsOneWidget);
    expect(find.text('Zrušit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('continueAccountDeletionButton')));
    await tester.pumpAndSettle();

    expect(
      openedUri,
      Uri.parse('https://viewvee.com/account/delete?accountId=42'),
    );
  });

  testWidgets('changes watch mode directly from the drawer without leaving', (
    tester,
  ) async {
    WatchMode? selectedMode;
    await tester.pumpWidget(
      buildSubject(onWatchModeChanged: (mode) async => selectedMode = mode),
    );

    await tester.tap(find.byKey(const Key('accountMenuButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawerMonitor')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profilePage')), findsOneWidget);
    expect(find.byKey(const Key('watchModePet')), findsOneWidget);

    await tester.tap(find.byKey(const Key('watchModePet')));
    await tester.pumpAndSettle();

    expect(selectedMode, WatchMode.pet);
    expect(find.byKey(const Key('profilePage')), findsOneWidget);
  });

  testWidgets('connected devices does not duplicate the watch mode choice', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.devices),
    );

    expect(find.byKey(const Key('devicesPage')), findsOneWidget);
    expect(find.text('Přidat zařízení'), findsOneWidget);
    expect(find.text('Režim sledování'), findsNothing);
    expect(find.byKey(const Key('watchModeMenuItem')), findsNothing);
  });

  testWidgets('add device opens a working role choice', (tester) async {
    DevicePairingAction? selectedAction;
    await tester.pumpWidget(
      buildSubject(
        initialDestination: ViewveeDrawerDestination.devices,
        onAddDevice: (action) async => selectedAction = action,
      ),
    );

    await tester.tap(find.byKey(const Key('addDeviceMenuItem')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('addCameraDevice')), findsOneWidget);
    expect(find.byKey(const Key('addMonitorDevice')), findsOneWidget);
    expect(find.textContaining('další verzi'), findsNothing);

    await tester.tap(find.byKey(const Key('addMonitorDevice')));
    await tester.pumpAndSettle();

    expect(selectedAction, DevicePairingAction.monitor);
  });

  testWidgets('changes language only in the local UI', (tester) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.preferences),
    );

    expect(find.byKey(const Key('languageSettingsTile')), findsOneWidget);
    expect(find.byKey(const Key('appearanceSettingsTile')), findsOneWidget);

    await tester.tap(find.byKey(const Key('languageMenuItem')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('English'));
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('switches appearance to dark mode', (tester) async {
    ThemeMode? selectedMode;
    await tester.pumpWidget(
      buildSubject(
        initialDestination: ViewveeDrawerDestination.preferences,
        onThemeModeChanged: (mode) async => selectedMode = mode,
      ),
    );

    await tester.tap(find.text('Tmavý'));
    await tester.pump();

    expect(selectedMode, ThemeMode.dark);
    final selector = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(selector.selected, {ThemeMode.dark});
  });

  testWidgets('drawer hides purchase options', (tester) async {
    await tester.pumpWidget(buildSubject());

    await tester.tap(find.byKey(const Key('accountMenuButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('drawerSubscription')), findsNothing);
    expect(find.byKey(const Key('subscriptionPage')), findsNothing);
    expect(find.byKey(const Key('startSubscriptionButton')), findsNothing);
  });

  testWidgets('recordings are locked for the free plan', (tester) async {
    await tester.pumpWidget(buildSubject(isPremium: false));

    await tester.tap(find.byKey(const Key('accountMenuButton')));
    await tester.pumpAndSettle();
    final recordingsItem = find.byKey(const Key('drawerRecordings'));
    expect(
      find.descendant(
        of: recordingsItem,
        matching: find.byIcon(Icons.lock_outline_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(recordingsItem);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('subscriptionPage')), findsOneWidget);
    expect(find.byKey(const Key('recordingsPage')), findsNothing);
  });

  testWidgets('about has separate content', (tester) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.about),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('aboutPage')), findsOneWidget);
    expect(find.text('Verze aplikace'), findsOneWidget);
  });

  testWidgets('support follows the grouped settings layout', (tester) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.support),
    );

    expect(find.byKey(const Key('supportPage')), findsOneWidget);
    expect(find.text('Jak vám můžeme pomoci?'), findsOneWidget);
    expect(find.text('KONTAKT'), findsOneWidget);
    expect(find.text('NÁPOVĚDA'), findsOneWidget);
    expect(find.byKey(const Key('contactSupportItem')), findsOneWidget);
    expect(find.text('Kontaktovat podporu'), findsOneWidget);
    expect(find.byKey(const Key('reportProblemItem')), findsNothing);
    expect(find.text('Nahlásit problém'), findsNothing);
    expect(find.byKey(const Key('faqItem')), findsOneWidget);
    expect(find.byKey(const Key('rateAppItem')), findsOneWidget);
  });

  testWidgets('contact support opens a prefilled form', (tester) async {
    SharedPreferences.setMockInitialValues({
      'profile.firstName': 'Jana',
      'profile.lastName': 'Nováková',
      'profile.email': 'jana@example.cz',
    });
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.support),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('contactSupportItem')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('supportNameField')), findsOneWidget);
    expect(find.byKey(const Key('supportEmailField')), findsOneWidget);
    expect(find.byKey(const Key('supportSubjectField')), findsOneWidget);
    expect(find.byKey(const Key('supportMessageField')), findsOneWidget);
    expect(find.byKey(const Key('supportRecipientInfo')), findsOneWidget);
    expect(find.text('support@specterint.com'), findsOneWidget);
    expect(find.text('Jana Nováková'), findsOneWidget);
    expect(find.text('jana@example.cz'), findsOneWidget);
  });

  testWidgets('app rating stores the selected number of stars', (tester) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.support),
    );

    await tester.ensureVisible(find.byKey(const Key('rateAppItem')));
    await tester.tap(find.byKey(const Key('rateAppItem')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratingColorHeader')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ratingStar5')));
    await tester.pump();
    expect(find.text('Děkujeme za vaše hodnocení.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('submitRatingButton')));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getInt('feedback.appRating'), 5);
    expect(find.text('Děkujeme za vaše hodnocení.'), findsOneWidget);
  });

  testWidgets('frequently asked questions contain expandable answers', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(initialDestination: ViewveeDrawerDestination.support),
    );

    await tester.ensureVisible(find.byKey(const Key('faqItem')));
    await tester.tap(find.byKey(const Key('faqItem')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('faqPage')), findsOneWidget);
    expect(find.text('Kolik telefonů potřebuji?'), findsOneWidget);
    expect(find.text('Jak telefony spáruji?'), findsOneWidget);
    expect(find.text('Je přenos obrazu a zvuku bezpečný?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('faqQuestion0')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Potřebujete dva telefony'), findsOneWidget);
  });
}
