import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_pairing.dart';

void main() {
  test(
    'pairing payload round-trips without exposing a joinable short code',
    () {
      final credentials = AudioPairingCredentials.generate();
      final parsed = AudioPairingCredentials.tryParse(
        credentials.toUriString(),
      );

      expect(parsed, isNotNull);
      expect(parsed!.roomCode, credentials.roomCode);
      expect(parsed.secret, credentials.secret);
      expect(parsed.sessionId, credentials.sessionId);
      expect(AudioPairingCredentials.tryParse(credentials.roomCode), isNull);
    },
  );

  test('local Wi-Fi pairing omits relay routing data', () {
    final credentials = AudioPairingCredentials.generate(
      mode: AudioPairingMode.wifi,
    );
    final parsed = AudioPairingCredentials.tryParse(
      credentials.toUriString(),
      expectedMode: AudioPairingMode.wifi,
    );

    expect(parsed?.roomCode, credentials.roomCode);
    expect(parsed?.secret, credentials.secret);
    expect(parsed?.sessionId, isNull);
    expect(
      AudioPairingCredentials.tryParse(
        credentials.toUriString(),
        expectedMode: AudioPairingMode.internet,
      ),
      isNull,
    );
  });

  test('secure signaling rejects tampering and replay', () {
    const sessionKey = 'test-session-key';
    final sender = SecureSignalingCodec(sessionKey);
    final receiver = SecureSignalingCodec(sessionKey);
    final envelope = sender.encode({
      'type': 'offer',
      'payload': {'sdp': 'test'},
    });

    expect(receiver.decode(envelope)['type'], 'offer');
    expect(() => receiver.decode(envelope), throwsFormatException);

    final tampered = sender.encode({'type': 'answer'});
    tampered['body'] = '{"type":"offer"}';
    expect(
      () => SecureSignalingCodec(sessionKey).decode(tampered),
      throwsFormatException,
    );
  });
}
