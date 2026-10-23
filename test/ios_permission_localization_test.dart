import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/localization/viewvee_localizations.dart';

void main() {
  test('every supported language bundles all iOS permission descriptions', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    for (final locale in ViewVeeLocalizations.supportedLocales) {
      var code = ViewVeeLocaleController.codeOf(locale);
      if (code == 'zh') code = 'zh-Hans';
      if (code == 'zh_Hant') code = 'zh-Hant';
      final content = File(
        'ios/Runner/$code.lproj/InfoPlist.strings',
      ).readAsStringSync();
      for (final key in [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSLocalNetworkUsageDescription',
        'NSUserTrackingUsageDescription',
      ]) {
        expect(
          RegExp('"$key" = "[^"]+";').hasMatch(content),
          isTrue,
          reason: '$code: $key',
        );
      }
      expect(project, contains('$code.lproj/InfoPlist.strings'));
    }
    expect(project, contains('InfoPlist.strings in Resources'));
  });
}
