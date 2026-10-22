import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/theme/viewvee_theme.dart';
import 'package:viewvee/widgets/viewvee_app_drawer.dart';

void main() {
  testWidgets('shows Working Timer-style grouped ViewVee menu', (tester) async {
    var profileOpened = false;
    SharedPreferences.setMockInitialValues({
      'profile.firstName': 'Jana',
      'profile.lastName': 'Nováková',
      'profile.email': 'jana@example.cz',
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildViewVeeTheme(),
        home: Scaffold(
          appBar: AppBar(
            leading: Builder(
              builder: (context) => IconButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(Icons.menu_rounded),
              ),
            ),
          ),
          drawer: ViewVeeAppDrawer(
            watchMode: WatchMode.baby,
            activeDestination: ViewVeeDrawerDestination.monitor,
            isPremium: true,
            onOpenMonitor: () {},
            onOpenDevices: () {},
            onOpenRecordings: () {},
            onOpenAccount: () => profileOpened = true,
            onOpenSubscription: () {},
            onOpenPreferences: () {},
            onOpenSupport: () {},
            onOpenAbout: () {},
            onSignOut: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Jana Nováková'), findsOneWidget);
    expect(find.text('jana@example.cz'), findsOneWidget);
    expect(find.byKey(const Key('drawerAccountButton')), findsNothing);
    expect(find.text('Odhlásit se'), findsOneWidget);
    expect(find.text('SLEDOVÁNÍ'), findsOneWidget);
    expect(find.text('Režim sledování'), findsOneWidget);
    expect(find.text('Nahrávky'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.text('ÚČET A APLIKACE'), findsOneWidget);
    expect(find.text('POMOC'), findsOneWidget);
    expect(find.text('Průvodce používáním'), findsNothing);
    expect(find.text('Dítě'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('viewveeAppDrawer'))).width,
      lessThanOrEqualTo(320),
    );

    await tester.tap(find.byKey(const Key('drawerProfile')));
    await tester.pumpAndSettle();

    expect(profileOpened, isTrue);
    expect(find.byKey(const Key('viewveeAppDrawer')), findsNothing);
  });
}
