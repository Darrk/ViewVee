import 'package:universal_io/io.dart';
import 'package:working_timer_core/working_timer_core.dart';

import 'firebase_options.dart';

class Config implements AuthConfig, ServicesConfig {
  @override
  String get authClientId => 'viewvee-app';

  @override
  String get authClientSecret => ''; // Public client (PKCE / no secret)

  @override
  String get authClientExtId => 'viewvee-app-ext';

  @override
  String get authClientExtSecret => ''; // Public client (no secret)

  @override
  String get authScopes => 'openid email profile offline_access viewvee-api';

  @override
  String get identityUrl => 'https://identity.specterint.com/';

  @override
  String get keyPKCEVerifier => 'keyPKCEVerifier';

  static final String termsUri = Platform.isIOS
      ? 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'
      : 'https://viewvee.com/terms-of-use.html';

  static const String privacyPolicyUrl =
      'https://viewvee.com/privacy-policy.html';

  @override
  String get apiUrl => 'https://viewvee.com/api/';

  static const String realtimeUrl = 'https://viewvee.com/api/';

  static const String dropboxClientId = 'a4n6pa1v6ylhnsj'; // TODO: use env. var

  @override
  String get googleClientId {
    if (Platform.isAndroid) {
      return '1091619601783-8esuvmlepls892s565mj4rcgt9lea17m.apps.googleusercontent.com';
    }

    if (Platform.isIOS) {
      return DefaultFirebaseOptions.ios.iosClientId ?? '';
    }

    return '';
  }

  @override
  String get appleClientId => 'com.specterint.viewvee';

  @override
  String get microsoftClientId => '';

  @override
  bool get enableExternalAuth => true;

  /// Temporary rollout switches for functionality not currently offered.
  static const bool enablePremiumFeatures = false;
  static const bool showPurchaseOptions = false;
  static const bool showFacebookLogin = false;
  static const bool showGoogleLogin = false;

  @override
  String get authRedirectUri =>
      '${const String.fromEnvironment('BASE_URL', defaultValue: 'http://localhost:43507/')}signin-oidc';

  @override
  String get homeUri => '';

  @override
  String get appUrl => '';

  static const int ratingPromptIntervalDays = 10;

  /// New users won't see fullscreen ads for this many days after first launch.
  static const int newUserAdsGracePeriodDays = 3;
}
