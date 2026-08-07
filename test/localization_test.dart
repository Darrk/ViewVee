import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';
import 'package:viewvee/main.dart';

void main() {
  test('supports the same 28 locale variants as BabyWave', () {
    expect(ViewveeLocalizations.supportedLocales, hasLength(28));
    expect(ViewveeLocalizations.supportedLocales, contains(const Locale('ar')));
    expect(
      ViewveeLocalizations.supportedLocales,
      contains(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
    );
  });

  testWidgets('uses the saved language throughout the app', (tester) async {
    SharedPreferences.setMockInitialValues({
      ViewveeLocaleController.preferenceKey: 'en',
    });

    await tester.pumpWidget(const ViewveeApp(previewAuthenticated: true));
    await tester.pumpAndSettle();

    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Pokračovat'), findsNothing);
  });

  test('registration is translated in every supported locale', () {
    const registrationSources = [
      'Registrace',
      'E-mail',
      'Heslo',
      'Heslo znovu',
      'Křestní jméno',
      'Příjmení',
      'Souhlasím s podmínkami použití',
      'Přečíst podmínky použití',
      'Toto pole je povinné',
      'Zadejte platný e-mail.',
      'Hesla se neshodují.',
      'Heslo musí mít alespoň 8 znaků.',
    ];
    for (final locale in ViewveeLocalizations.supportedLocales) {
      final localizations = ViewveeLocalizations(locale);
      for (final source in registrationSources) {
        expect(
          localizations.translate(source),
          isNotEmpty,
          reason: '${locale.toLanguageTag()}: $source',
        );
      }
    }
    const english = ViewveeLocalizations(Locale('en'));
    expect(english.translate('Registrace'), 'Sign Up');
    expect(english.translate('Heslo znovu'), 'Confirm Password');
    expect(english.translate('Křestní jméno'), 'First Name');
    expect(english.translate('Příjmení'), 'Last Name');
    expect(
      english.translate('Souhlasím s podmínkami použití'),
      'I have read and agree to the Terms and Conditions',
    );
  });

  test('system language option is localized', () {
    const english = ViewveeLocalizations(Locale('en'));
    const german = ViewveeLocalizations(Locale('de'));
    expect(english.translate('Podle systému'), 'System default');
    expect(german.translate('Podle systému'), 'Systemeinstellung');
  });
}
