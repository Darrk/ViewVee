import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/turn_credentials_service.dart' show AccessTokenLoader;
import '../auth/auth_repository.dart';

/// The API refused a purchase that another account already redeemed.
class PurchaseOwnedElsewhere implements Exception {
  const PurchaseOwnedElsewhere();
}

/// Store events are verified by the API before delivery and acknowledgement.
/// Signed-in purchases are bound to the account by the API, which is then the
/// source of truth for Premium. Guests may buy too (App Store 5.1.1(v)); their
/// purchase stays on the device until they sign in and it is claimed.
class PremiumPurchaseService extends ChangeNotifier {
  PremiumPurchaseService({
    InAppPurchase? store,
    this.verifyPurchase,
    this.fetchEntitlement,
    AccessTokenLoader? getAccessToken,
  }) : _storeOverride = store,
       _getAccessToken = getAccessToken;
  final InAppPurchase? _storeOverride;
  final Future<bool> Function(Map<String, dynamic>)? verifyPurchase;

  /// Returns the account's Premium state, or null when no account is signed in.
  final Future<bool?> Function()? fetchEntitlement;
  final AccessTokenLoader? _getAccessToken;

  static const unavailableMessage =
      'Premium teď není k dispozici. Zkuste to prosím později.';
  static const ownedElsewhereMessage =
      'Tento nákup už patří jinému účtu ViewVee.';
  static const _genericError = 'Něco se pokazilo. Zkuste to prosím znovu.';
  @visibleForTesting
  Future<void> get eventsSettled => _events;

  static final instance = PremiumPurchaseService();
  static String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'apple' : 'google';

  static String get productId {
    const override = String.fromEnvironment('VIEWVEE_PREMIUM_PRODUCT_ID');
    if (override.isNotEmpty) return override;
    return platform == 'apple'
        ? const String.fromEnvironment(
            'VIEWVEE_APPLE_PREMIUM_PRODUCT_ID',
            defaultValue: 'viewvee_premium',
          )
        : const String.fromEnvironment(
            'VIEWVEE_GOOGLE_PREMIUM_PRODUCT_ID',
            defaultValue: 'premium',
          );
  }

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

  /// Sets up the store once; while the product is missing, each call (e.g.
  /// reopening the Premium screen) tries to load it again.
  Future<void> initialize() async {
    final firstCall = _initialization == null;
    await (_initialization ??= _initialize());
    if (!firstCall && supported && product == null) {
      await (_productLoad ??= _loadProduct().whenComplete(
        () => _productLoad = null,
      ));
    }
  }

  Future<void>? _productLoad;

  Future<void> _initialize() async {
    if (!supported) return;
    _subscription ??= _store.purchaseStream.listen(
      (purchases) {
        _events = _events.then((_) => _handle(purchases));
      },
      onError: (Object e) {
        debugPrint('ViewVee purchases: purchase stream error: $e');
        _fail();
      },
    );
    entitled = await hasEntitlement();
    await _cacheEntitlement(entitled);
    await refreshEntitlement();
    await _loadProduct();
    // Play refunds purchases left unacknowledged for three days. Re-deliver
    // any that missed verification so they are verified and acknowledged.
    // StoreKit re-delivers unfinished transactions on its own.
    if (defaultTargetPlatform == TargetPlatform.android && product != null) {
      try {
        await _store.restorePurchases();
      } catch (e) {
        debugPrint('ViewVee purchases: background restore failed: $e');
      }
    }
  }

  /// Loads the store product. Failing to load is not a user error, so it only
  /// shows that Premium is unavailable and logs the reason for diagnosis.
  Future<void> _loadProduct() async {
    try {
      if (!await _store.isAvailable()) {
        _unavailable(
          'store not available (no Play Store / App Store account?)',
        );
        return;
      }
      final result = await _store.queryProductDetails({productId});
      if (result.error != null) {
        _unavailable('product query failed: ${result.error}');
        return;
      }
      if (result.productDetails.isEmpty) {
        _unavailable(
          'product "$productId" not found '
          '(notFoundIDs: ${result.notFoundIDs}). Check it is active in the '
          'store and this build/account can see it.',
        );
        return;
      }
      product = result.productDetails.firstWhere(
        (value) => value.id == productId,
      );
      error = null;
    } catch (e) {
      _unavailable('product load threw: $e');
      return;
    }
    notifyListeners();
  }

  void _unavailable(String reason) {
    debugPrint('ViewVee purchases: $reason');
    _fail(unavailableMessage);
  }

  /// Syncs Premium with the signed-in account, so a purchase made on another
  /// device unlocks this one without a store restore. Offline keeps the cache.
  Future<void> refreshEntitlement() async {
    bool? active;
    try {
      active = await (fetchEntitlement?.call() ?? _fetchEntitlement());
    } catch (_) {
      return;
    }
    // Guests have no account entitlement; recheck their saved store proof too.
    if (active != true) {
      // A purchase verified before accounts were bound is claimed now.
      try {
        final saved = await _storage.read(key: _proofKey);
        final proof = saved == null
            ? null
            : Map<String, dynamic>.from(jsonDecode(saved) as Map);
        if (proof != null && proof['verificationData'] != null) {
          active = await (verifyPurchase?.call(proof) ?? verify(proof));
        }
      } on PurchaseOwnedElsewhere {
        active = false;
      } catch (_) {
        return;
      }
    }
    if (active == null) return;
    if (active) {
      if (await _storage.read(key: _proofKey) == null) {
        await _storage.write(
          key: _proofKey,
          value: jsonEncode({'productId': productId, 'source': 'account'}),
        );
      }
    } else {
      await _storage.delete(key: _proofKey);
    }
    await _cacheEntitlement(active);
  }

  /// Forgets the cached entitlement, e.g. on sign-out, so the next account
  /// starts from its own server state.
  Future<void> clearCachedEntitlement() async {
    try {
      await _storage.delete(key: _proofKey);
    } catch (_) {}
    await _cacheEntitlement(false);
  }

  Future<String?> _accessToken({bool forceRefresh = false}) async {
    try {
      final load = _getAccessToken ?? AuthRepository().getAccessToken;
      return await load(forceRefresh: forceRefresh);
    } catch (_) {
      return null;
    }
  }

  /// Sends the request with the account token when signed in, refreshing it
  /// once after a 401. Guests send no token.
  Future<http.Response> _authorized(
    String method,
    Uri endpoint,
    http.Client transport, {
    String? body,
  }) async {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw StateError('Purchase verification requires HTTPS.');
    }
    var token = await _accessToken();
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, endpoint)..followRedirects = false;
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request
          ..headers['Content-Type'] = 'application/json'
          ..body = body;
      }
      final response = await http.Response.fromStream(
        await transport.send(request),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 401 || token == null || attempt > 0) {
        return response;
      }
      token = await _accessToken(forceRefresh: true);
    }
  }

  Future<bool?> _fetchEntitlement({http.Client? client}) async {
    if (await _accessToken() == null) return null;
    final transport = client ?? http.Client();
    try {
      final response = await _authorized(
        'GET',
        Uri.parse(
          const String.fromEnvironment(
            'VIEWVEE_PURCHASE_ENTITLEMENT_URL',
            defaultValue: 'https://viewvee.com/api/purchases/entitlement',
          ),
        ).replace(queryParameters: {'platform': platform}),
        transport,
      );
      if (response.statusCode != 200) {
        throw StateError('Entitlement unavailable.');
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
          'platform': platform,
          'productId': productId,
          'transactionId': purchase.purchaseID,
          'verificationData': purchase.verificationData.serverVerificationData,
        };
        try {
          if (!await (verifyPurchase?.call(proof) ?? verify(proof))) {
            await clearCachedEntitlement();
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
        } on PurchaseOwnedElsewhere {
          // Finish it: the purchase is valid, it just unlocks another account.
          if (purchase.pendingCompletePurchase) {
            await _store.completePurchase(purchase);
          }
          _fail(ownedElsewhereMessage);
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
    final transport = client ?? http.Client();
    try {
      final response = await _authorized(
        'POST',
        endpoint,
        transport,
        body: jsonEncode(proof),
      );
      if (response.statusCode == 409) throw const PurchaseOwnedElsewhere();
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

  void _fail([String message = _genericError]) {
    busy = false;
    error = message;
    notifyListeners();
  }
}
