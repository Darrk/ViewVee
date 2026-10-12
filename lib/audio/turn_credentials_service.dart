import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_repository.dart';

typedef AccessTokenLoader = Future<String?> Function({bool forceRefresh});

class TurnCredentials {
  const TurnCredentials({
    required this.urls,
    required this.username,
    required this.credential,
    required this.expiresAt,
  });

  final List<String> urls;
  final String username;
  final String credential;
  final DateTime expiresAt;

  Map<String, dynamic> toIceServer() => {
    'urls': urls,
    'username': username,
    'credential': credential,
  };

  factory TurnCredentials.fromJson(Map<String, dynamic> json, DateTime now) {
    final urls = json['urls'];
    final username = json['username'];
    final credential = json['credential'];
    final expiresAt = json['expiresAt'] is String
        ? DateTime.tryParse(json['expiresAt'] as String)
        : null;
    if (urls is! List ||
        urls.isEmpty ||
        urls.any((url) => url is! String || !_validTurnUrl(url)) ||
        username is! String ||
        username.isEmpty ||
        credential is! String ||
        credential.isEmpty ||
        expiresAt == null ||
        !expiresAt.isAfter(now.add(const Duration(minutes: 1)))) {
      throw const FormatException('Invalid or expired TURN credentials.');
    }
    return TurnCredentials(
      urls: urls.cast<String>(),
      username: username,
      credential: credential,
      expiresAt: expiresAt.toUtc(),
    );
  }

  static bool _validTurnUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'turn' || uri.scheme == 'turns') &&
        uri.path.isNotEmpty;
  }
}

class TurnCredentialsService {
  TurnCredentialsService({
    Uri? endpoint,
    this.getAccessToken,
    this.client,
    DateTime Function()? now,
  }) : _endpoint =
           endpoint ??
           Uri.parse(
             const String.fromEnvironment(
               'VIEWVEE_TURN_CREDENTIALS_URL',
               defaultValue: 'https://viewvee.com/api/turn/credentials',
             ),
           ),
       _now = now ?? DateTime.now;

  final Uri _endpoint;
  final AccessTokenLoader? getAccessToken;
  late final AuthRepository _auth = AuthRepository();
  final http.Client? client;
  final DateTime Function() _now;

  /// Fetch for each new peer connection, including reconnections after expiry.
  /// A signed-in user's API failure is surfaced instead of silently losing TURN.
  Future<TurnCredentials?> fetch() async {
    final getToken = getAccessToken ?? _auth.getAccessToken;
    var token = await getToken(forceRefresh: false);
    if (token == null) return null;
    if (_endpoint.scheme != 'https' ||
        _endpoint.host.isEmpty ||
        _endpoint.userInfo.isNotEmpty ||
        _endpoint.hasFragment) {
      throw StateError('The TURN credentials endpoint must use HTTPS.');
    }
    final requestClient = client ?? http.Client();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final request = http.Request('GET', _endpoint)
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token'
          ..headers['Accept'] = 'application/json';
        final response = await (() async {
          final streamed = await requestClient.send(request);
          return http.Response.fromStream(streamed);
        })().timeout(const Duration(seconds: 10));
        if (response.statusCode == 401 && attempt == 0) {
          token = await getToken(forceRefresh: true);
          if (token == null) throw StateError('Sign in again to use TURN.');
          continue;
        }
        if (response.statusCode != 200) {
          throw StateError(
            'TURN credentials request failed (${response.statusCode}).',
          );
        }
        final body = jsonDecode(response.body);
        if (body is! Map<String, dynamic>) {
          throw const FormatException('Invalid TURN credentials response.');
        }
        return TurnCredentials.fromJson(body, _now().toUtc());
      }
      throw StateError('TURN authentication failed.');
    } finally {
      if (client == null) requestClient.close();
    }
  }
}
