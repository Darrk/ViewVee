import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';

void main() {
  test('every localized literal has a native translation in all locales', () {
    final sources = <String>{};
    final literalPattern = RegExp(
      r'''(?:VvText|\.vv)\(\s*((?:'(?:[^'\\]|\\.)*'\s*|"(?:[^"\\]|\\.)*"\s*)+)|(?:title|subtitle|label|question|answer|description|tooltip|semanticLabel|labelText|hintText|helperText|errorText)\s*:\s*((?:'(?:[^'\\]|\\.)*'\s*|"(?:[^"\\]|\\.)*"\s*)+)''',
      dotAll: true,
    );
    final stringPattern = RegExp(
      r'''['"]((?:[^'"\\]|\\.)*)['"]''',
      dotAll: true,
    );
    const invariantSources = <String>{
      'ViewVee',
      'HD',
      'SD',
      'SEE MORE. CARE MORE.',
      'VIEWVEE PREMIUM',
      'support@specterint.com',
      'ViewVee Free',
      '1.0.0 (1)',
      'Verze 1.0.0',
    };
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('/localization/')) continue;
      final contents = entity.readAsStringSync();
      for (final match in literalPattern.allMatches(contents)) {
        final literalSequence = match.group(1) ?? match.group(2) ?? '';
        final source = stringPattern
            .allMatches(literalSequence)
            .map((literal) => literal.group(1) ?? '')
            .join();
        if (!source.contains(r'$') && !invariantSources.contains(source)) {
          sources.add(source);
        }
      }
    }
    sources.addAll(ViewveeLocalizations.fallbackSources);
    sources.addAll(const <String>{
      'Wi-Fi monitoring • 1 hodina',
      'SD kvalita',
      'Internet pouze s Premium',
      'Bez nahrávání videa',
      'Reklama po každé hodině sledování',
      'Neomezený internet',
      'HD video',
      'Nahrávání videa • pouze lokálně',
      'Obousměrný zvuk',
      'Žádné reklamy',
      'Neomezená délka spojení',
      'Podle systému',
      'Pozastavit',
      'Přehrát',
    });

    final missing = <String>[];
    for (final source in sources.toList()..sort()) {
      final missingLocales = ViewveeLocalizations.supportedLocales
          .where(
            (locale) =>
                !ViewveeLocalizations.hasNativeTranslation(source, locale),
          )
          .map(ViewveeLocaleController.codeOf)
          .toList();
      if (missingLocales.isNotEmpty) {
        missing.add('$source: ${missingLocales.join(', ')}');
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'Missing native translations:\n${missing.join('\n')}',
    );
  });
}
