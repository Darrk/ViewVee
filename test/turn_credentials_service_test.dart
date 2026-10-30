import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:viewvee/audio/turn_credentials_service.dart';

void main() {
  final now = DateTime.utc(2026, 10, 12, 12);
  Map<String, dynamic> credentials({DateTime? expires}) => {
    'urls': ['turns:turn.viewvee.com:443?transport=tcp'],
    'username': 'test-user',
    'credential': 'test-password',
    'expiresAt': (expires ?? now.add(const Duration(hours: 1)))
        .toIso8601String(),
  };

  test(
    'fetches credentials anew for each connection with bearer auth',
    () async {
      var requests = 0;
      final service = TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => 'access-token',
        now: () => now,
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/api/turn/credentials');
          expect(request.headers['Authorization'], 'Bearer access-token');
          expect(request.followRedirects, isFalse);
          return http.Response(jsonEncode(credentials()), 200);
        }),
      );
      final result = await service.fetch();
      expect(result!.expiresAt, now.add(const Duration(hours: 1)));
      expect(result.toIceServer(), {
        'urls': ['turns:turn.viewvee.com:443?transport=tcp'],
        'username': 'test-user',
        'credential': 'test-password',
      });
      await service.fetch();
      expect(requests, 2);
    },
  );

  test(
    '401 triggers one silent refresh and retries with the new token',
    () async {
      final refreshes = <bool>[];
      var requests = 0;
      final service = TurnCredentialsService(
        now: () => now,
        getAccessToken: ({bool forceRefresh = false}) async {
          refreshes.add(forceRefresh);
          return forceRefresh ? 'new-token' : 'old-token';
        },
        client: MockClient((request) async {
          requests++;
          if (requests == 1) return http.Response('', 401);
          expect(request.headers['Authorization'], 'Bearer new-token');
          return http.Response(jsonEncode(credentials()), 200);
        }),
      );
      expect(await service.fetch(), isNotNull);
      expect(refreshes, [false, true]);
    },
  );

  test(
    'repeated 401 does not retry indefinitely or fall back to STUN',
    () async {
      var requests = 0;
      final service = TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => 'token',
        client: MockClient((_) async {
          requests++;
          return http.Response('', 401);
        }),
      );
      await expectLater(service.fetch(), throwsStateError);
      expect(requests, 2);
    },
  );

  test('unauthenticated users do not request credentials', () async {
    final service = TurnCredentialsService(
      getAccessToken: ({bool forceRefresh = false}) async => null,
      client: MockClient((_) async => fail('must not call API')),
    );
    expect(await service.fetch(), isNull);
  });

  test('rejects expired, malformed and non-TURN server responses', () async {
    for (final body in [
      credentials(expires: now.subtract(const Duration(seconds: 1))),
      credentials(expires: now.add(const Duration(seconds: 30))),
      {
        ...credentials(),
        'urls': ['https://example.com'],
      },
      {...credentials(), 'credential': ''},
      {...credentials(), 'expiresAt': 'invalid'},
      {'urls': []},
    ]) {
      final service = TurnCredentialsService(
        now: () => now,
        getAccessToken: ({bool forceRefresh = false}) async => 'token',
        client: MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      await expectLater(service.fetch(), throwsFormatException);
    }
  });

  test('rejects HTTP endpoints before exposing the access token', () async {
    final service = TurnCredentialsService(
      endpoint: Uri.parse('http://example.com/api/turn/credentials'),
      getAccessToken: ({bool forceRefresh = false}) async => 'token',
      client: MockClient((_) async => fail('must not send token over HTTP')),
    );
    await expectLater(service.fetch(), throwsStateError);
  });

  test('surfaces unavailable API and redirects', () async {
    for (final status in [302, 403, 429, 503]) {
      final service = TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => 'token',
        client: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(service.fetch(), throwsStateError);
    }
  });
}
