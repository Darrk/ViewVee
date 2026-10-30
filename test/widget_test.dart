// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/auth/working_timer_auth.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';
import 'package:viewvee/main.dart';
import 'package:working_timer_core/working_timer_core.dart';

class _FakeWorkingTimerAuth implements WorkingTimerAuth {
  String? signUpError;
  bool signedIn = false;

  @override
  Future<String> getAccessToken() async => 'test-access-token';

  @override
  Future<WorkingTimerUser?> getLocalUser() async => null;

  @override
  Future<String> getLastEmail() async => '';

  @override
  Future<bool> hasAccount() async => signedIn;

  @override
  Future<bool> isAccessTokenExpired() async => false;

  @override
  Future<bool> hasConnection() async => true;

  @override
  Future<bool> trySilentSignIn() async => false;

  @override
  Future<String> signIn(String email, String password) async {
    signedIn = true;
    return '';
  }

  @override
  Future<ApiResult<UserModel>?> signUp(
    String email,
    String password,
    String firstName,
    String lastName,
    String app,
  ) async => signUpError == null
      ? ApiResult<UserModel>.success(
          UserModel(
            userId: 1,
            firstName: firstName,
            lastName: lastName,
            email: email,
            isConfirmed: false,
          ),
        )
      : ApiResult<UserModel>.error(signUpError!);

  @override
  Future<bool> signInWithApple() async => true;

  @override
  Future<bool> signInWithFacebook() async => true;

  @override
  Future<bool> signInWithGoogle() async => true;

  @override
  Future<bool> forgotPassword(String email) async => true;

  @override
  Future<bool> signOut() async => true;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      ViewVeeLocaleController.preferenceKey: 'cs',
    });
  });

  testWidgets('login with a saved mode offers all monitoring types', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ViewVeeLocaleController.preferenceKey: 'cs',
      'profile.watchMode': 'baby',
    });
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: _FakeWorkingTimerAuth())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openSignIn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('emailField')),
      'user@example.com',
    );
    await tester.enterText(find.byKey(const Key('passwordField')), 'password1');
    await tester.ensureVisible(find.byKey(const Key('authSubmit')));
    await tester.tap(find.byKey(const Key('authSubmit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('modeBaby')), findsOneWidget);
    expect(find.byKey(const Key('modePet')), findsOneWidget);
    expect(find.byKey(const Key('modeHome')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('modeHome')));
    await tester.tap(find.byKey(const Key('modeHome')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('continueSetup')));
    await tester.tap(find.byKey(const Key('continueSetup')));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('profile.watchMode'), 'home');
    expect(find.text('Kamera'), findsOneWidget);
    expect(find.text('Monitor'), findsOneWidget);
    expect(find.text('Miminko'), findsNothing);
    expect(find.text('Rodič'), findsNothing);
  });

  testWidgets('shows animated logo during initial session restore', (
    tester,
  ) async {
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: _FakeWorkingTimerAuth())),
    );
    await tester.pump();

    expect(find.byKey(const Key('animatedSplashLogo')), findsOneWidget);
    expect(find.byKey(const Key('animatedEyeHighlight')), findsOneWidget);
    expect(find.text('Spolehlivý dohled, ať jste kdekoliv.'), findsNothing);

    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pumpAndSettle();
    expect(find.text('Spolehlivý dohled, ať jste kdekoliv.'), findsOneWidget);
  });

  testWidgets('restores the saved dark appearance globally', (tester) async {
    SharedPreferences.setMockInitialValues({
      'preferences.themeMode': ThemeMode.dark.name,
      ViewVeeLocaleController.preferenceKey: 'cs',
    });

    await tester.pumpWidget(const ViewVeeApp(previewAuthenticated: true));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('Režim sledování'));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('authentication chooser offers guest access and opens forms', (
    tester,
  ) async {
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: _FakeWorkingTimerAuth())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Spolehlivý dohled, ať jste kdekoliv.'), findsOneWidget);
    expect(find.text('Přihlaste se nebo si vytvořte účet.'), findsNothing);
    expect(find.text('Pokračovat bez přihlášení'), findsOneWidget);
    expect(find.byKey(const Key('signInApple')), findsNothing);
    expect(find.byKey(const Key('signInFacebook')), findsNothing);
    expect(find.byKey(const Key('signInGoogle')), findsNothing);
    expect(find.text('Pokračovat přes Apple'), findsNothing);
    expect(find.text('Pokračovat přes Facebook'), findsNothing);
    expect(find.text('Pokračovat přes Google'), findsNothing);

    await tester.tap(find.byKey(const Key('openSignIn')));
    await tester.pumpAndSettle();
    expect(find.text('Přihlásit se'), findsWidgets);
    expect(find.byKey(const Key('emailField')), findsOneWidget);

    await tester.tap(find.byTooltip('Zpět'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openRegister')));
    await tester.pumpAndSettle();
    expect(find.text('Registrace'), findsWidgets);
    expect(find.byKey(const Key('passwordConfirmationField')), findsOneWidget);
  });

  testWidgets('registration shows Working Timer sign-up failure inline', (
    tester,
  ) async {
    final auth = _FakeWorkingTimerAuth()
      ..signUpError = 'User with the given email already exists.';
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: auth)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('openRegister')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('emailField')),
      'user@example.com',
    );
    await tester.enterText(find.byKey(const Key('passwordField')), 'password1');
    await tester.enterText(
      find.byKey(const Key('passwordConfirmationField')),
      'password1',
    );
    await tester.enterText(find.byKey(const Key('firstNameField')), 'Jan');
    await tester.enterText(find.byKey(const Key('lastNameField')), 'Novák');
    final terms = find.byKey(const Key('termsAccepted'));
    await tester.ensureVisible(terms);
    await tester.tap(terms);
    final submit = find.byKey(const Key('authSubmit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(
      find.text('Něco se pokazilo. Zkuste to prosím znovu.'),
      findsOneWidget,
    );
  });

  testWidgets('successful registration stores the registered profile', (
    tester,
  ) async {
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: _FakeWorkingTimerAuth())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('openRegister')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('emailField')),
      'jana.novakova@example.cz',
    );
    await tester.enterText(find.byKey(const Key('passwordField')), 'password1');
    await tester.enterText(
      find.byKey(const Key('passwordConfirmationField')),
      'password1',
    );
    await tester.enterText(find.byKey(const Key('firstNameField')), 'Jana');
    await tester.enterText(find.byKey(const Key('lastNameField')), 'Nováková');
    final terms = find.byKey(const Key('termsAccepted'));
    await tester.ensureVisible(terms);
    await tester.tap(terms);
    final submit = find.byKey(const Key('authSubmit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(AuthRepository.profileFirstNameKey), 'Jana');
    expect(
      preferences.getString(AuthRepository.profileLastNameKey),
      'Nováková',
    );
    expect(
      preferences.getString(AuthRepository.profileEmailKey),
      'jana.novakova@example.cz',
    );
  });

  testWidgets('sign-in form is fully localized in English', (tester) async {
    SharedPreferences.setMockInitialValues({
      ViewVeeLocaleController.preferenceKey: 'en',
    });
    await tester.pumpWidget(
      ViewVeeApp(authRepository: AuthRepository(auth: _FakeWorkingTimerAuth())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('openSignIn')));
    await tester.pumpAndSettle();

    expect(find.text('Sign In'), findsWidgets);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Forgot Password'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
    expect(find.text('Přihlásit se'), findsNothing);
    expect(find.text('Heslo'), findsNothing);
    expect(find.text('Zapomenuté heslo?'), findsNothing);

    await tester.tap(find.text('Forgot Password'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('forgotPasswordEmailField')), findsOneWidget);
    expect(find.byKey(const Key('passwordField')), findsNothing);
    expect(find.text('Forgot Password'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Back to Login'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('forgotPasswordEmailField')),
      'user@example.com',
    );
    final send = find.byKey(const Key('forgotPasswordSubmit'));
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(
      find.text('Password reset link has been sent to your email'),
      findsOneWidget,
    );
  });

  testWidgets('guest access opens setup and survives app restoration', (
    tester,
  ) async {
    final repository = AuthRepository(auth: _FakeWorkingTimerAuth());
    await tester.pumpWidget(ViewVeeApp(authRepository: repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continueAsGuest')));
    await tester.pumpAndSettle();

    expect(find.text('Režim sledování'), findsOneWidget);
    final restored = await repository.restoreSession();
    expect(restored.isSignedIn, isTrue);
    expect(restored.isGuest, isTrue);
  });
}
