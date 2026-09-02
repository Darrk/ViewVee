import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const _authContext = 'viewvee-signaling-v1';

enum AudioPairingMode { wifi, internet }

class AudioPairingCredentials {
  const AudioPairingCredentials({
    required this.roomCode,
    required this.secret,
    this.mode = AudioPairingMode.internet,
    this.sessionId,
  });

  static const scheme = 'viewvee';
  static const host = 'monitor';
  static const protocolVersion = '1';
  static const secretByteLength = 32;
  static const sessionByteLength = 16;

  final String roomCode;
  final String secret;
  final AudioPairingMode mode;
  final String? sessionId;

  factory AudioPairingCredentials.generate({
    AudioPairingMode mode = AudioPairingMode.internet,
    Random? random,
  }) {
    final secureRandom = random ?? Random.secure();
    String randomValue(int length) => base64Url
        .encode(List<int>.generate(length, (_) => secureRandom.nextInt(256)))
        .replaceAll('=', '');

    return AudioPairingCredentials(
      roomCode: List.generate(6, (_) => secureRandom.nextInt(10)).join(),
      secret: randomValue(secretByteLength),
      mode: mode,
      sessionId: mode == AudioPairingMode.internet
          ? randomValue(sessionByteLength)
          : null,
    );
  }

  String toUriString() => Uri(
    scheme: scheme,
    host: host,
    pathSegments: [roomCode],
    queryParameters: {
      'v': protocolVersion,
      'mode': mode.name,
      'secret': secret,
      'session': ?sessionId,
    },
  ).toString();

  static AudioPairingCredentials? tryParse(
    String value, {
    AudioPairingMode? expectedMode,
  }) {
    final uri = Uri.tryParse(value.trim());
    final mode = switch (uri?.queryParameters['mode']) {
      'wifi' => AudioPairingMode.wifi,
      'internet' => AudioPairingMode.internet,
      _ => null,
    };
    if (uri == null ||
        uri.scheme != scheme ||
        uri.host != host ||
        uri.pathSegments.length != 1 ||
        uri.queryParameters['v'] != protocolVersion ||
        mode == null ||
        (expectedMode != null && mode != expectedMode)) {
      return null;
    }
    final roomCode = uri.pathSegments.single;
    final secret = uri.queryParameters['secret'];
    final sessionId = uri.queryParameters['session'];
    if (!RegExp(r'^\d{6}$').hasMatch(roomCode) ||
        !_validBase64Value(secret, secretByteLength) ||
        (mode == AudioPairingMode.internet &&
            !_validBase64Value(sessionId, sessionByteLength)) ||
        (mode == AudioPairingMode.wifi && sessionId != null)) {
      return null;
    }
    return AudioPairingCredentials(
      roomCode: roomCode,
      secret: secret!,
      mode: mode,
      sessionId: sessionId,
    );
  }

  static bool _validBase64Value(String? value, int byteLength) {
    if (value == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      return false;
    }
    try {
      return base64Url.decode(base64Url.normalize(value)).length == byteLength;
    } on FormatException {
      return false;
    }
  }
}

String deriveAudioSessionKey({
  required String secret,
  required String sessionId,
  required String epoch,
}) {
  final key = utf8.encode('$_authContext:$secret');
  return Hmac(
    sha256,
    key,
  ).convert(utf8.encode('session:$sessionId:$epoch')).toString();
}

String deriveLocalAudioSessionKey({
  required String secret,
  required String serverNonce,
  required String clientNonce,
}) {
  final key = utf8.encode('$_authContext:$secret');
  return Hmac(
    sha256,
    key,
  ).convert(utf8.encode('local:$serverNonce:$clientNonce')).toString();
}

String computeLocalPairingMac(String secret, String payload) {
  return Hmac(
    sha256,
    utf8.encode('$_authContext:$secret'),
  ).convert(utf8.encode(payload)).toString();
}

class SecureSignalingCodec {
  SecureSignalingCodec(this._sessionKey);

  static const maxBodyLength = 256 * 1024;
  final String _sessionKey;
  int _sendSequence = 0;
  int _lastReceivedSequence = 0;

  Map<String, dynamic> encode(Map<String, dynamic> message) {
    final sequence = ++_sendSequence;
    final body = jsonEncode(message);
    if (body.length > maxBodyLength) {
      throw const FormatException('Signaling message is too large.');
    }
    return {
      'type': 'secure',
      'seq': sequence,
      'body': body,
      'mac': _mac(sequence, body),
    };
  }

  Map<String, dynamic> decode(Map<String, dynamic> envelope) {
    final sequence = envelope['seq'];
    final body = envelope['body'];
    final mac = envelope['mac'];
    if (envelope['type'] != 'secure' ||
        sequence is! int ||
        sequence <= _lastReceivedSequence ||
        body is! String ||
        body.length > maxBodyLength ||
        mac is! String ||
        !_constantTimeEquals(_mac(sequence, body), mac)) {
      throw const FormatException('Invalid secure signaling message.');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Invalid signaling body.');
    }
    _lastReceivedSequence = sequence;
    return Map<String, dynamic>.from(decoded);
  }

  String _mac(int sequence, String body) => Hmac(
    sha256,
    utf8.encode(_sessionKey),
  ).convert(utf8.encode('$sequence:$body')).toString();
}

bool _constantTimeEquals(String first, String second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
  }
  return difference == 0;
}
