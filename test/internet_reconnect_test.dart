import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/internet_audio_signaling.dart';
import 'package:viewvee/audio/audio_pairing.dart';

void main() {
  test(
    'camera re-registers the same pairing after its relay socket closes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final registrations = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          if (message['type'] == 'register') {
            registrations.add(message);
            socket.add(jsonEncode({'type': 'registered'}));
            socket.add(
              jsonEncode({
                'type': 'peer_ready',
                'epoch': 'epoch-${sockets.length}',
              }),
            );
          }
        });
      });
      final signaling = InternetAudioSignaling(
        serverUri: Uri.parse('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        await signaling.hangUp();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      final ready = Completer<void>();
      final disconnected = Completer<void>();
      signaling.onPeerReady = () {
        if (!ready.isCompleted) ready.complete();
      };
      signaling.onRemoteHangup = () {
        if (!disconnected.isCompleted) disconnected.complete();
      };
      await signaling.createRoom(credentials: AudioPairingCredentials.generate());
      await ready.future.timeout(const Duration(seconds: 5));
      final pairing = signaling.pairingUri;
      await sockets.single.close();
      await disconnected.future.timeout(const Duration(seconds: 5));

      await signaling.rearmForNewPeer();
      expect(registrations, hasLength(2));
      expect(registrations.last['session'], registrations.first['session']);
      expect(registrations.last['role'], 'transmitter');
      expect(signaling.pairingUri, pairing);
      await signaling.hangUp();
      final restored = InternetAudioSignaling(
        serverUri: Uri.parse('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(restored.hangUp);
      await restored.createRoom(
        credentials: AudioPairingCredentials.tryParse(pairing!),
      );
      expect(restored.pairingUri, pairing);
      expect(registrations.last['session'], registrations.first['session']);
      expect(registrations.last['role'], 'transmitter');
    },
  );
}
