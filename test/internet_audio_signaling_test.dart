import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/internet_audio_signaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late Uri uri;
  late List<WebSocket> sockets;
  late List<Map<String, dynamic>> registrations;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sockets = [];
    registrations = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('ws://127.0.0.1:${server.port}/viewvee/ws');
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] == 'register') {
          registrations.add(message);
          socket.add(jsonEncode({'type': 'registered'}));
        }
      });
    });
  });

  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });

  test('restarted camera registers the original pairing session', () async {
    final first = InternetAudioSignaling(serverUri: uri);
    await first.createRoom();
    final pairing = first.pairingUri;
    await first.hangUp();
    final restarted = InternetAudioSignaling(serverUri: uri);
    await restarted.createRoom();
    expect(restarted.pairingUri, pairing);
    expect(registrations[1]['session'], registrations[0]['session']);
    await restarted.hangUp();
  });

  test(
    'camera re-registers after socket loss even while waiting for a monitor',
    () async {
      final camera = InternetAudioSignaling(serverUri: uri);
      final disconnected = Completer<void>();
      camera.onRemoteHangup = () {
        if (!disconnected.isCompleted) disconnected.complete();
      };
      await camera.createRoom();
      final pairing = camera.pairingUri;
      await sockets.single.close();
      await disconnected.future.timeout(const Duration(seconds: 3));
      await camera.rearmForNewPeer();
      expect(registrations.length, 2);
      expect(camera.pairingUri, pairing);
      await camera.hangUp();
    },
  );

  test('media recovery replaces a stale signaling connection', () async {
    final camera = InternetAudioSignaling(serverUri: uri);
    await camera.createRoom();
    await camera.rearmForNewPeer();
    expect(registrations.length, 2);
    expect(registrations.last['session'], registrations.first['session']);
    await camera.hangUp();
  });
}
