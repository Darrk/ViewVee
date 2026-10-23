import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_repository.dart';

class AccountDeletionService {
  AccountDeletionService({this.client, this.appleCode, this.getAccessToken});
  late final AuthRepository _defaultAuth = AuthRepository();
  final Future<String?> Function({bool forceRefresh})? getAccessToken;
  final http.Client? client;
  final Future<String> Function()? appleCode;

  Future<void> delete() async {
    final transport = client ?? http.Client();
    try {
      String? code;
      var refresh = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        final token = await (getAccessToken ?? _defaultAuth.getAccessToken)(
          forceRefresh: refresh,
        );
        if (token == null) throw StateError('Přihlaste se prosím znovu.');
        final endpoint = Uri.parse(
          const String.fromEnvironment(
            'VIEWVEE_ACCOUNT_DELETE_URL',
            defaultValue: 'https://viewvee.com/api/account',
          ),
        );
        if (endpoint.scheme != 'https' || endpoint.userInfo.isNotEmpty) {
          throw StateError('Account deletion requires HTTPS.');
        }
        final request = http.Request('DELETE', endpoint)
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'confirmed': true,
            'appleAuthorizationCode': ?code,
          });
        final response = await (() async {
          return http.Response.fromStream(await transport.send(request));
        })().timeout(const Duration(seconds: 15));
        if (response.statusCode == 204) return;
        if (response.statusCode == 401 && !refresh) {
          refresh = true;
          continue;
        }
        if (response.statusCode == 409 && code == null) {
          code = await (appleCode?.call() ?? _reauthorizeApple());
          continue;
        }
        throw StateError('Účet se nepodařilo smazat. Zkuste to prosím znovu.');
      }
      throw StateError('Přihlaste se prosím znovu.');
    } finally {
      if (client == null) transport.close();
    }
  }

  Future<String> _reauthorizeApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(scopes: []);
    return credential.authorizationCode;
  }
}
