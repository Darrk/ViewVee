import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewvee/purchases/premium_purchase_service.dart';

class _Store extends Fake implements InAppPurchase {
  final events = StreamController<List<PurchaseDetails>>.broadcast(sync: true);
  final completed = <PurchaseDetails>[];
  int restored = 0;
  @override
  Stream<List<PurchaseDetails>> get purchaseStream => events.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async => ProductDetailsResponse(
    productDetails: [
      ProductDetails(
        id: PremiumPurchaseService.productId,
        title: 'Premium',
        description: 'Lifetime',
        price: r'$12.34',
        rawPrice: 12.34,
        currencyCode: 'USD',
      ),
    ],
    notFoundIDs: [],
  );
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restored++;
  }
}

PurchaseDetails _purchase() => PurchaseDetails(
  purchaseID: '42',
  productID: PremiumPurchaseService.productId,
  verificationData: PurchaseVerificationData(
    localVerificationData: '',
    serverVerificationData: 'signed-proof',
    source: 'app_store',
  ),
  transactionDate: '0',
  status: PurchaseStatus.purchased,
)..pendingCompletePurchase = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  test(
    'delivery and store completion wait for successful server verification',
    () async {
      final store = _Store();
      final verified = Completer<bool>();
      final service = PremiumPurchaseService(
        store: store,
        verifyPurchase: (_) => verified.future,
      );
      await service.initialize();
      expect(service.product!.price, r'$12.34');
      store.events.add([_purchase()]);
      await Future<void>.delayed(Duration.zero);
      expect(store.completed, isEmpty);
      expect(await service.hasEntitlement(), isFalse);
      verified.complete(true);
      await service.eventsSettled;
      expect(await service.hasEntitlement(), isTrue);
      expect(store.completed, hasLength(1));
      await service.restore();
      expect(store.restored, 1);
      service.dispose();
      await store.events.close();
    },
  );
  test(
    'failed verification never unlocks or acknowledges the transaction',
    () async {
      final store = _Store();
      final service = PremiumPurchaseService(
        store: store,
        verifyPurchase: (_) async => false,
      );
      await service.initialize();
      store.events.add([_purchase()]);
      await service.eventsSettled;
      expect(service.entitled, isFalse);
      expect(store.completed, isEmpty);
      expect(await service.hasEntitlement(), isFalse);
      service.dispose();
      await store.events.close();
    },
  );
  test('refund clears a previously verified entitlement at startup', () async {
    FlutterSecureStorage.setMockInitialValues({
      'purchase.verifiedPremium.v1': jsonEncode({
        'productId': PremiumPurchaseService.productId,
      }),
    });
    final store = _Store();
    final service = PremiumPurchaseService(
      store: store,
      verifyPurchase: (_) async => false,
    );
    await service.initialize();
    expect(await service.hasEntitlement(), isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        PremiumPurchaseService.entitlementKey,
      ),
      isFalse,
    );
    service.dispose();
    await store.events.close();
  });
  test(
    'verification rejects redirects, outages, and another product',
    () async {
      final service = PremiumPurchaseService();
      for (final status in [302, 503]) {
        final client = MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return http.Response('', status);
        });
        await expectLater(service.verify({}, client: client), throwsStateError);
      }
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'active': true, 'productId': 'another-product'}),
          200,
        ),
      );
      await expectLater(
        service.verify({}, client: client),
        throwsFormatException,
      );
      service.dispose();
    },
  );
}
