import 'package:shared_preferences/shared_preferences.dart';

import 'working_timer_auth.dart';

enum WatchMode { baby, pet, home }

enum AuthProvider { apple, facebook, google }

class AppSession {
  const AppSession({
    required this.isSignedIn,
    required this.isGuest,
    this.accountId,
    this.watchMode,
    this.isPremium = false,
  });

  final bool isSignedIn;
  final bool isGuest;
  final int? accountId;
  final WatchMode? watchMode;
  final bool isPremium;
}

class AuthRepository {
  AuthRepository({WorkingTimerAuth? auth})
    : _auth = auth ?? SpecterWorkingTimerAuth();

  static const _guestKey = 'auth.guest';
  static const _modeKey = 'profile.watchMode';
  static const premiumUnlockedKey = 'subscription.premiumUnlocked';
  static const profileFirstNameKey = 'profile.firstName';
  static const profileLastNameKey = 'profile.lastName';
  static const profileEmailKey = 'profile.email';

  final WorkingTimerAuth _auth;

  Future<AppSession> restoreSession() async {
    final preferences = await SharedPreferences.getInstance();
    final guest = preferences.getBool(_guestKey) ?? false;
    final authenticated = guest ? false : await _restoreIdentitySession();
    final identityUser = authenticated
        ? await _syncProfileFromIdentity()
        : null;
    final modeName = preferences.getString(_modeKey);
    WatchMode? watchMode;
    for (final mode in WatchMode.values) {
      if (mode.name == modeName) watchMode = mode;
    }
    return AppSession(
      isSignedIn: authenticated || guest,
      isGuest: guest,
      accountId: identityUser?.id,
      watchMode: watchMode,
      isPremium: preferences.getBool(premiumUnlockedKey) ?? false,
    );
  }

  Future<void> signIn({required String email, required String password}) async {
    _validateCredentials(email, password);
    final error = await _auth.signIn(email.trim(), password);
    if (error.isNotEmpty) throw AuthException(error);
    await _clearGuestSession();
    await _syncProfileFromIdentity(fallbackEmail: email.trim());
  }

  Future<void> signInWithProvider(AuthProvider provider) async {
    final signedIn = switch (provider) {
      AuthProvider.apple => await _auth.signInWithApple(),
      AuthProvider.facebook => await _auth.signInWithFacebook(),
      AuthProvider.google => await _auth.signInWithGoogle(),
    };
    if (!signedIn) {
      throw const AuthException('Přihlášení bylo zrušeno nebo se nezdařilo.');
    }
    await _clearGuestSession();
    await _syncProfileFromIdentity(clearWhenUnavailable: true);
  }

  Future<void> continueAsGuest() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_guestKey, true);
    await _clearStoredProfile(preferences);
  }

  Future<void> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    _validateCredentials(email, password);
    if (firstName.trim().isEmpty || lastName.trim().isEmpty) {
      throw const AuthException('Toto pole je povinné');
    }
    final result = await _auth.signUp(
      email.trim(),
      password,
      firstName.trim(),
      lastName.trim(),
      'workingtimer',
    );
    if (result == null || !result.isOk()) {
      throw AuthException(
        result?.error ?? 'Něco se pokazilo. Zkuste to prosím znovu.',
      );
    }
    await signIn(email: email, password: password);
    await _syncProfileFromIdentity(
      fallbackFirstName: firstName.trim(),
      fallbackLastName: lastName.trim(),
      fallbackEmail: email.trim(),
    );
  }

  Future<String> getLastEmail() => _auth.getLastEmail();

  Future<void> forgotPassword(String email) async {
    final normalizedEmail = email.trim();
    if (!normalizedEmail.contains('@') || !normalizedEmail.contains('.')) {
      throw const AuthException('Zadejte platný e-mail.');
    }
    if (!await _auth.forgotPassword(normalizedEmail)) {
      throw const AuthException('Něco se pokazilo. Zkuste to prosím znovu.');
    }
  }

  Future<void> saveWatchMode(WatchMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_modeKey, mode.name);
  }

  Future<void> signOut() async {
    final preferences = await SharedPreferences.getInstance();
    final guest = preferences.getBool(_guestKey) ?? false;
    if (!guest) await _auth.signOut();
    await preferences.remove(_guestKey);
    await _clearStoredProfile(preferences);
  }

  Future<void> _clearGuestSession() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_guestKey);
  }

  Future<WorkingTimerUser?> _syncProfileFromIdentity({
    String fallbackFirstName = '',
    String fallbackLastName = '',
    String fallbackEmail = '',
    bool clearWhenUnavailable = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    WorkingTimerUser? identityUser;
    try {
      identityUser = await _auth.getLocalUser();
    } on Exception {
      identityUser = null;
    }

    final firstName = identityUser?.firstName.trim().isNotEmpty == true
        ? identityUser!.firstName.trim()
        : fallbackFirstName.trim();
    final lastName = identityUser?.lastName.trim().isNotEmpty == true
        ? identityUser!.lastName.trim()
        : fallbackLastName.trim();
    final email = identityUser?.email.trim().isNotEmpty == true
        ? identityUser!.email.trim()
        : fallbackEmail.trim();

    if (identityUser == null &&
        firstName.isEmpty &&
        lastName.isEmpty &&
        email.isEmpty) {
      if (clearWhenUnavailable) await _clearStoredProfile(preferences);
      return null;
    }

    await Future.wait([
      firstName.isEmpty
          ? preferences.remove(profileFirstNameKey)
          : preferences.setString(profileFirstNameKey, firstName),
      lastName.isEmpty
          ? preferences.remove(profileLastNameKey)
          : preferences.setString(profileLastNameKey, lastName),
      email.isEmpty
          ? preferences.remove(profileEmailKey)
          : preferences.setString(profileEmailKey, email),
    ]);
    return identityUser;
  }

  Future<void> _clearStoredProfile([SharedPreferences? preferences]) async {
    final store = preferences ?? await SharedPreferences.getInstance();
    await Future.wait([
      store.remove(profileFirstNameKey),
      store.remove(profileLastNameKey),
      store.remove(profileEmailKey),
    ]);
  }

  Future<bool> _restoreIdentitySession() async {
    if (!await _auth.hasAccount()) return false;
    if (!await _auth.isAccessTokenExpired()) return true;
    if (!await _auth.hasConnection()) return true;
    return _auth.trySilentSignIn();
  }

  static void _validateCredentials(String email, String password) {
    final normalizedEmail = email.trim();
    if (!normalizedEmail.contains('@') || !normalizedEmail.contains('.')) {
      throw const AuthException('Zadejte platný e-mail.');
    }
    if (password.length < 8) {
      throw const AuthException('Heslo musí mít alespoň 8 znaků.');
    }
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;
}
