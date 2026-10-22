import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';
import 'package:viewvee/main.dart';

void main() {
  test('device roles use neutral labels for all monitoring types', () {
    const english = ViewVeeLocalizations(Locale('en'));
    const czech = ViewVeeLocalizations(Locale('cs'));
    expect(english.translate('Kamera'), 'Camera');
    expect(english.translate('Monitor'), 'Monitor');
    expect(czech.translate('Kamera'), 'Kamera');
    expect(czech.translate('Monitor'), 'Monitor');
  });

  test('supports the same 28 locale variants as BabyWave', () {
    expect(ViewVeeLocalizations.supportedLocales, hasLength(28));
    expect(ViewVeeLocalizations.supportedLocales, contains(const Locale('ar')));
    expect(
      ViewVeeLocalizations.supportedLocales,
      contains(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
    );
  });

  testWidgets('uses the saved language throughout the app', (tester) async {
    SharedPreferences.setMockInitialValues({
      ViewVeeLocaleController.preferenceKey: 'en',
    });

    await tester.pumpWidget(const ViewVeeApp(previewAuthenticated: true));
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
    for (final locale in ViewVeeLocalizations.supportedLocales) {
      final localizations = ViewVeeLocalizations(locale);
      for (final source in registrationSources) {
        expect(
          localizations.translate(source),
          isNotEmpty,
          reason: '${locale.toLanguageTag()}: $source',
        );
      }
    }
    const english = ViewVeeLocalizations(Locale('en'));
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
    const english = ViewVeeLocalizations(Locale('en'));
    const german = ViewVeeLocalizations(Locale('de'));
    expect(english.translate('Podle systému'), 'System default');
    expect(german.translate('Podle systému'), 'Systemeinstellung');
  });
}
