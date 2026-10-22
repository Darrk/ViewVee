import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:universal_io/io.dart';
import 'package:working_timer_core/working_timer_core.dart';

class ViewVeeAuthConfig implements AuthConfig, ServicesConfig {
  @override
  String get authClientId => 'working-timer-app';

  @override
  String get authClientSecret => '33fd7b5d-5be2-4649-a20d-c5f740e87575';

  @override
  String get authClientExtId => 'working-timer-app-ext';

  @override
  String get authClientExtSecret => '377d51c7-cad8-4e46-a692-7b4d63e7a4ae';

  @override
  String get authScopes => const String.fromEnvironment(
    'VIEWVEE_AUTH_SCOPES',
    defaultValue: 'openid email profile offline_access viewvee-api',
  );

  @override
  String get identityUrl => const String.fromEnvironment(
    'VIEWVEE_IDENTITY_URL',
    defaultValue: 'https://identity.specterint.com/',
  );

  @override
  String get keyPKCEVerifier => 'keyPKCEVerifier';

  @override
  String get googleClientId => Platform.isAndroid
      ? '1091619601783-8esuvmlepls892s565mj4rcgt9lea17m.apps.googleusercontent.com'
      : '';

  @override
  String get appleClientId => 'com.specterinteractive.workingtimer';

  @override
  String get microsoftClientId => '';

  @override
  bool get enableExternalAuth => true;

  @override
  String get authRedirectUri => 'http://localhost:43507/signin-oidc';

  @override
  String get homeUri => 'http://localhost:43507/';

  @override
  String get appUrl => 'http://localhost:43507/';

  @override
  String get apiUrl => 'https://wt-api.specterint.com/';
}

abstract class WorkingTimerAuth {
  Future<String> getAccessToken();
  Future<bool> hasAccount();
  Future<bool> isAccessTokenExpired();
  Future<bool> hasConnection();
  Future<bool> trySilentSignIn();
  Future<WorkingTimerUser?> getLocalUser();
  Future<String> getLastEmail();
  Future<String> signIn(String email, String password);
  Future<ApiResult<UserModel>?> signUp(
    String email,
    String password,
    String firstName,
    String lastName,
    String app,
  );
  Future<bool> signInWithApple();
  Future<bool> signInWithFacebook();
  Future<bool> signInWithGoogle();
  Future<bool> forgotPassword(String email);
  Future<bool> signOut();
}

class WorkingTimerUser {
  const WorkingTimerUser({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final int id;
  final String firstName;
  final String lastName;
  final String email;
}

class SpecterWorkingTimerAuth implements WorkingTimerAuth {
  SpecterWorkingTimerAuth() : _services = _sharedServices ??= _createServices();

  // LocalStorage.init() assigns a `late final` static, so the services must be
  // created once per process and shared by every instance.
  static Future<({Identity identity, IdentityService identityService})>?
  _sharedServices;

  final Future<({Identity identity, IdentityService identityService})>
  _services;

  static Future<({Identity identity, IdentityService identityService})>
  _createServices() async {
    await LocalStorage.init();
    // ViewVee does not ship a Firebase project configuration yet. Keep the
    // shared authentication client usable without initializing Firebase-only
    // analytics from Working Timer Core.
    Analytics.isTest = true;
    final config = ViewVeeAuthConfig();
    final identityService = IdentityService(
      config: config,
      analytics: Analytics(),
    );
    final localStorage = LocalStorage(
      useOnlySecured: true,
      secureStorage: const FlutterSecureStorage(),
    );
    return (
      identity: Identity(identityService, config, localStorage),
      identityService: identityService,
    );
  }

  @override
  Future<String> getAccessToken() async =>
      (await _services).identity.getAccessToken();

  @override
  Future<bool> hasAccount() async => (await _services).identity.hasAccount();

  @override
  Future<bool> isAccessTokenExpired() async =>
      (await _services).identity.isAccessTokenExpired();

  @override
  Future<bool> hasConnection() => ConnectionCheck.check();

  @override
  Future<bool> trySilentSignIn() async =>
      (await _services).identity.trySilentSignIn();

  @override
  Future<WorkingTimerUser?> getLocalUser() async {
    final user = await (await _services).identity.getLocalUser();
    if (user.userId <= 0 && user.email.trim().isEmpty) return null;
    return WorkingTimerUser(
      id: user.userId,
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
    );
  }

  @override
  Future<String> getLastEmail() async =>
      (await _services).identity.getLastEmail();

  @override
  Future<String> signIn(String email, String password) async =>
      (await _services).identity.signIn(email, password);

  @override
  Future<ApiResult<UserModel>?> signUp(
    String email,
    String password,
    String firstName,
    String lastName,
    String app,
  ) async => (await _services).identityService.signUp(
    email,
    password,
    firstName,
    lastName,
    app,
  );

  @override
  Future<bool> signInWithApple() async =>
      (await _services).identity.signInWithApple();

  @override
  Future<bool> signInWithFacebook() async =>
      (await _services).identity.signInWithFacebook();

  @override
  Future<bool> signInWithGoogle() async =>
      (await _services).identity.signInWithGoogle();

  @override
  Future<bool> forgotPassword(String email) async =>
      (await _services).identityService.forgotPassword(email);

  @override
  Future<bool> signOut() async => (await _services).identity.signOut();
}
