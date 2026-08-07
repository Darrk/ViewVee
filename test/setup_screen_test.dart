import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/screens/setup_screen.dart';
import 'package:viewvee/theme/viewvee_theme.dart';

void main() {
  testWidgets('requires a mode before continuing', (tester) async {
    WatchMode? selectedMode;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildViewveeTheme(),
        home: SetupScreen(onSelected: (mode) => selectedMode = mode),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Režim sledování'), findsOneWidget);
    expect(find.text('Vysoká citlivost'), findsOneWidget);
    expect(find.text('Vyvážená citlivost'), findsOneWidget);
    expect(find.text('Nižší citlivost'), findsOneWidget);

    final continueButton = find.byKey(const Key('continueSetup'));
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(selectedMode, isNull);

    await tester.tap(find.byKey(const Key('modePet')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);

    expect(selectedMode, WatchMode.pet);
  });
}
