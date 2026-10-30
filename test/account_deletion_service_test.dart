import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:viewvee/auth/account_deletion_service.dart';

void main() {
  test(
    'deletion refreshes credentials and binds Apple reauthorization to retry',
    () async {
      var calls = 0;
      final refreshes = <bool>[];
      final service = AccountDeletionService(
        getAccessToken: ({bool forceRefresh = false}) async {
          refreshes.add(forceRefresh);
          return forceRefresh ? 'new-token' : 'old-token';
        },
        appleCode: () async => 'one-use-apple-code',
        client: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map;
          expect(body['confirmed'], isTrue);
          expect(body.containsKey('accountId'), isFalse);
          calls++;
          if (calls == 1) return http.Response('', 401);
          if (calls == 2) return http.Response('', 409);
          expect(request.headers['Authorization'], 'Bearer new-token');
          expect(body['appleAuthorizationCode'], 'one-use-apple-code');
          return http.Response('', 204);
        }),
      );
      await service.delete();
      expect(calls, 3);
      expect(refreshes, [false, true, true]);
    },
  );
  test(
    'a failed deletion remains a failure and never claims success',
    () async {
      final service = AccountDeletionService(
        getAccessToken: ({bool forceRefresh = false}) async => 'token',
        client: MockClient((_) async => http.Response('', 503)),
      );
      await expectLater(service.delete(), throwsStateError);
    },
  );
  test('signed-out users cannot submit deletion', () async {
    final service = AccountDeletionService(
      getAccessToken: ({bool forceRefresh = false}) async => null,
      client: MockClient(
        (_) async => fail('No request may be sent without authentication'),
      ),
    );
    await expectLater(service.delete(), throwsStateError);
  });
}
