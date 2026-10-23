import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:viewvee/ads/ad_consent_service.dart';

class _Consent extends Fake implements ConsentInformation {
  final updated = Completer<void>();
  var allowed = false;
  var updates = 0;
  @override
  void requestConsentInfoUpdate(
    ConsentRequestParameters params,
    OnConsentInfoUpdateSuccessListener success,
    OnConsentInfoUpdateFailureListener failure,
  ) {
    updates++;
    updated.future.then((_) => success());
  }

  @override
  Future<bool> canRequestAds() async => allowed;
  @override
  Future<PrivacyOptionsRequirementStatus>
  getPrivacyOptionsRequirementStatus() async =>
      PrivacyOptionsRequirementStatus.required;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ad requests await consent; withdrawal is checked again and exposes privacy controls',
    () async {
      final previous = ConsentInformation.instance;
      final consent = _Consent();
      ConsentInformation.instance = consent;
      final service = AdConsentService();
      const channel = MethodChannel('plugins.flutter.io/google_mobile_ads/ump');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() {
        ConsentInformation.instance = previous;
        messenger.setMockMethodCallHandler(channel, null);
        service.dispose();
      });
      var completed = false;
      final permission = service.canRequestAds().then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(calls, isEmpty);
      consent.allowed = true;
      consent.updated.complete();
      expect(await permission, isTrue);
      expect(
        calls,
        contains('UserMessagingPlatform#loadAndShowConsentFormIfRequired'),
      );
      expect(service.privacyOptionsRequired, isTrue);
      consent.allowed = false;
      expect(await service.canRequestAds(), isFalse);
      await service.showPrivacyOptions();
      expect(service.generation, 1);
      expect(consent.updates, 1);
    },
  );
}
