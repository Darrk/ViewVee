import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Store events are verified by the API before delivery and acknowledgement.
class PremiumPurchaseService extends ChangeNotifier {
  PremiumPurchaseService({InAppPurchase? store, this.verifyPurchase})
    : _storeOverride = store;
  final InAppPurchase? _storeOverride;
  final Future<bool> Function(Map<String, dynamic>)? verifyPurchase;
  @visibleForTesting
  Future<void> get eventsSettled => _events;

  static final instance = PremiumPurchaseService();
  static const productId = String.fromEnvironment(
    'VIEWVEE_PREMIUM_PRODUCT_ID',
    defaultValue: 'viewvee.premium.lifetime',
  );
  static const _proofKey = 'purchase.verifiedPremium.v1';
  static const entitlementKey = 'subscription.premiumUnlocked';
  static const _storage = FlutterSecureStorage();
  InAppPurchase get _store => _storeOverride ?? InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  Future<void>? _initialization;
  Future<void> _events = Future.value();
  ProductDetails? product;
  bool busy = false;
  bool entitled = false;
  bool entitlementLoaded = false;
  String? error;
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<bool> hasEntitlement() async {
    // A legacy preference alone is not a purchase entitlement.
    try {
      return await _storage.read(key: _proofKey) != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    if (!supported) return;
    _subscription ??= _store.purchaseStream.listen(
      (purchases) {
        _events = _events.then((_) => _handle(purchases));
      },
      onError: (_) {
        _fail();
      },
    );
    entitled = await hasEntitlement();
    await _cacheEntitlement(entitled);
    try {
      final saved = await _storage.read(key: _proofKey);
      if (saved != null) {
        final proof = Map<String, dynamic>.from(jsonDecode(saved) as Map);
        try {
          final active = await (verifyPurchase?.call(proof) ?? verify(proof));
          if (!active) await _storage.delete(key: _proofKey);
          await _cacheEntitlement(active);
        } catch (_) {
          // Previously verified lifetime purchases remain usable offline.
        }
      }
      if (!await _store.isAvailable()) {
        _fail();
        return;
      }
      final result = await _store.queryProductDetails({productId});
      if (result.error != null || result.productDetails.isEmpty) {
        _fail();
        return;
      }
      product = result.productDetails.singleWhere(
        (value) => value.id == productId,
      );
      error = null;
    } catch (_) {
      _fail();
    }
    notifyListeners();
  }

  Future<void> buy() async {
    if (busy) return;
    await initialize();
    if (product == null) {
      _fail();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product!),
      )) {
        _fail();
      }
    } catch (_) {
      _fail();
    }
  }

  Future<void> restore() async {
    if (busy) return;
    await initialize();
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _store.restorePurchases();
    } catch (_) {
      _fail();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _handle(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != productId) continue;
      if (purchase.status == PurchaseStatus.pending) {
        busy = true;
        notifyListeners();
        continue;
      }
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        final proof = <String, dynamic>{
          'platform': defaultTargetPlatform == TargetPlatform.iOS
              ? 'apple'
              : 'google',
          'productId': productId,
          'transactionId': purchase.purchaseID,
          'verificationData': purchase.verificationData.serverVerificationData,
        };
        try {
          if (!await (verifyPurchase?.call(proof) ?? verify(proof))) {
            _fail();
            continue;
          }
          await _storage.write(key: _proofKey, value: jsonEncode(proof));
          await _cacheEntitlement(true);
          // Complete only after the verified entitlement has been delivered.
          if (purchase.pendingCompletePurchase) {
            await _store.completePurchase(purchase);
          }
          error = null;
        } catch (_) {
          // Leave the transaction unfinished so StoreKit/Play can redeliver it.
          _fail();
        }
      } else if (purchase.status == PurchaseStatus.error) {
        _fail();
      }
      busy = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  Future<bool> verify(Map<String, dynamic> proof, {http.Client? client}) async {
    final endpoint = Uri.parse(
      const String.fromEnvironment(
        'VIEWVEE_PURCHASE_VERIFY_URL',
        defaultValue: 'https://viewvee.com/api/purchases/verify',
      ),
    );
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw StateError('Purchase verification requires HTTPS.');
    }
    final transport = client ?? http.Client();
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(proof);
      final response = await http.Response.fromStream(
        await transport.send(request),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 422) return false;
      if (response.statusCode != 200) {
        throw StateError('Purchase verification unavailable.');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['productId'] != productId) {
        throw const FormatException('Unexpected product.');
      }
      return body['active'] == true;
    } finally {
      if (client == null) transport.close();
    }
  }

  Future<void> _cacheEntitlement(bool value) async {
    entitled = value;
    entitlementLoaded = true;
    await (await SharedPreferences.getInstance()).setBool(
      entitlementKey,
      value,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _fail() {
    busy = false;
    error = 'Něco se pokazilo. Zkuste to prosím znovu.';
    notifyListeners();
  }
}
