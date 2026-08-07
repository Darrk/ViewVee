import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/auth/auth_repository.dart';
import 'package:viewvee/auth/working_timer_auth.dart';
import 'package:working_timer_core/working_timer_core.dart';

class FakeWorkingTimerAuth implements WorkingTimerAuth {
  bool account = false;
  bool expired = false;
  bool connected = true;
  bool silentSignInResult = true;
  String signInError = '';
  String lastEmail = '';
  WorkingTimerUser? localUser;
  ApiResult<UserModel>? signUpResult;
  AuthProvider? provider;
  List<String>? signUpArguments;
  var silentSignInCalls = 0;
  var signInCalls = 0;

  @override
  Future<bool> hasAccount() async => account;

  @override
  Future<bool> isAccessTokenExpired() async => expired;

  @override
  Future<bool> hasConnection() async => connected;

  @override
  Future<bool> trySilentSignIn() async {
    silentSignInCalls++;
    return silentSignInResult;
  }

  @override
  Future<WorkingTimerUser?> getLocalUser() async => localUser;

  @override
  Future<String> getLastEmail() async => lastEmail;

  @override
  Future<String> signIn(String email, String password) async {
    signInCalls++;
    return signInError;
  }

  @override
  Future<ApiResult<UserModel>?> signUp(
    String email,
    String password,
    String firstName,
    String lastName,
    String app,
  ) async {
    signUpArguments = [email, password, firstName, lastName, app];
    return signUpResult;
  }

  @override
  Future<bool> signInWithApple() async {
    provider = AuthProvider.apple;
    return true;
  }

  @override
  Future<bool> signInWithFacebook() async {
    provider = AuthProvider.facebook;
    return true;
  }

  @override
  Future<bool> signInWithGoogle() async {
    provider = AuthProvider.google;
    return true;
  }

  @override
  Future<bool> forgotPassword(String email) async => true;

  @override
  Future<bool> signOut() async => true;
}

UserModel _user() => UserModel(
  userId: 1,
  firstName: 'Jan',
  lastName: 'Novak',
  email: 'user@example.com',
  isConfirmed: false,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('existing unexpired Working Timer account restores session', () async {
    final auth = FakeWorkingTimerAuth()..account = true;

    final session = await AuthRepository(auth: auth).restoreSession();

    expect(session.isSignedIn, isTrue);
    expect(session.isGuest, isFalse);
    expect(auth.silentSignInCalls, 0);
  });

  test('expired online account uses Working Timer silent sign in', () async {
    final auth = FakeWorkingTimerAuth()
      ..account = true
      ..expired = true;

    final session = await AuthRepository(auth: auth).restoreSession();

    expect(session.isSignedIn, isTrue);
    expect(auth.silentSignInCalls, 1);
  });

  test('registration uses Working Timer arguments and signs in', () async {
    final auth = FakeWorkingTimerAuth()
      ..signUpResult = ApiResult<UserModel>.success(_user());

    await AuthRepository(auth: auth).register(
      email: ' user@example.com ',
      password: 'password1',
      firstName: ' Jan ',
      lastName: ' Novak ',
    );

    expect(auth.signUpArguments, [
      'user@example.com',
      'password1',
      'Jan',
      'Novak',
      'workingtimer',
    ]);
    expect(auth.signInCalls, 1);
  });

  test('sign in restores the registered Working Timer identity', () async {
    final auth = FakeWorkingTimerAuth()
      ..localUser = const WorkingTimerUser(
        id: 42,
        firstName: 'Jana',
        lastName: 'Nováková',
        email: 'jana@example.cz',
      );
    final repository = AuthRepository(auth: auth);

    await repository.signIn(email: 'jana@example.cz', password: 'password1');

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(AuthRepository.profileFirstNameKey), 'Jana');
    expect(
      preferences.getString(AuthRepository.profileLastNameKey),
      'Nováková',
    );
    expect(
      preferences.getString(AuthRepository.profileEmailKey),
      'jana@example.cz',
    );
  });

  test('restored session also restores its Working Timer identity', () async {
    final auth = FakeWorkingTimerAuth()
      ..account = true
      ..localUser = const WorkingTimerUser(
        id: 42,
        firstName: 'Jana',
        lastName: 'Nováková',
        email: 'jana@example.cz',
      );

    await AuthRepository(auth: auth).restoreSession();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(AuthRepository.profileFirstNameKey), 'Jana');
    expect(
      preferences.getString(AuthRepository.profileLastNameKey),
      'Nováková',
    );
  });

  test('provider sign in calls native Working Timer provider method', () async {
    final auth = FakeWorkingTimerAuth();

    await AuthRepository(auth: auth).signInWithProvider(AuthProvider.google);

    expect(auth.provider, AuthProvider.google);
  });

  test('guest preference restores a guest session', () async {
    SharedPreferences.setMockInitialValues({'auth.guest': true});

    final session = await AuthRepository(
      auth: FakeWorkingTimerAuth(),
    ).restoreSession();

    expect(session.isSignedIn, isTrue);
    expect(session.isGuest, isTrue);
  });

  test('continue as guest persists the session', () async {
    final repository = AuthRepository(auth: FakeWorkingTimerAuth());

    await repository.continueAsGuest();
    final session = await repository.restoreSession();

    expect(session.isSignedIn, isTrue);
    expect(session.isGuest, isTrue);
  });

  test('expired offline account remains available', () async {
    final auth = FakeWorkingTimerAuth()
      ..account = true
      ..expired = true
      ..connected = false;

    final session = await AuthRepository(auth: auth).restoreSession();

    expect(session.isSignedIn, isTrue);
    expect(auth.silentSignInCalls, 0);
  });
}
