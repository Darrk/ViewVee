import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as websocket_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio_pairing.dart';
import 'audio_pairing_repository.dart';
import 'audio_signaling.dart';

class InternetAudioSignaling implements AudioSignaling {
  InternetAudioSignaling({
    required Uri serverUri,
    AudioPairingRepository? pairingRepository,
  }) : _serverUri = serverUri,
       _pairingRepository = pairingRepository ?? AudioPairingRepository() {
    if (serverUri.scheme != 'wss' &&
        !(kDebugMode && serverUri.scheme == 'ws')) {
      throw ArgumentError('Audio signaling requires a secure wss:// URL.');
    }
  }

  static const _connectTimeout = Duration(seconds: 10);
  static const _joinTimeout = Duration(seconds: 35);

  final Uri _serverUri;
  final AudioPairingRepository _pairingRepository;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _registered;
  Completer<void>? _peerReady;
  AudioPairingCredentials? _credentials;
  SecureSignalingCodec? _codec;
  String? _role;
  bool _hadPeer = false;
  bool _closing = false;

  @override
  void Function()? onPeerReady;
  @override
  void Function(Map<String, dynamic> description)? onOffer;
  @override
  void Function(Map<String, dynamic> description)? onAnswer;
  @override
  void Function(Map<String, dynamic> candidate)? onCandidate;
  @override
  void Function(Map<String, dynamic> message)? onControl;
  @override
  void Function()? onRemoteHangup;

  @override
  String? get roomCode => _credentials?.roomCode;
  @override
  String? get pairingUri => _credentials?.toUriString();

  @override
  Future<String> createRoom() async {
    _credentials = await _pairingRepository.cameraCredentials(
      AudioPairingMode.internet,
    );
    _role = 'transmitter';
    await _connectAndRegister();
    return roomCode!;
  }

  @override
  Future<bool> joinRoom(String pairingValue) async {
    final credentials = AudioPairingCredentials.tryParse(
      pairingValue,
      expectedMode: AudioPairingMode.internet,
    );
    if (credentials == null) return false;
    _credentials = credentials;
    _role = 'receiver';
    await _connectAndRegister();
    await _peerReady!.future.timeout(_joinTimeout);
    return true;
  }

  Future<void> _connectAndRegister() async {
    final credentials = _credentials;
    final role = _role;
    if (credentials == null || role == null) {
      throw StateError('Missing pairing credentials.');
    }
    await _closeSocket(notifyPeer: false);
    _closing = false;
    _hadPeer = false;
    _registered = Completer<void>();
    _peerReady = role == 'receiver' ? Completer<void>() : null;
    // Registration can fail before joinRoom starts awaiting peer readiness.
    _peerReady?.future.ignore();

    final channel = WebSocketChannel.connect(_serverUri);
    _channel = channel;
    _subscription = channel.stream.listen(
      (raw) {
        if (identical(_channel, channel)) _handleMessage(raw);
      },
      onError: (Object error) {
        if (identical(_channel, channel)) _handleSocketFailure(error);
      },
      onDone: () {
        if (identical(_channel, channel)) {
          _handleSocketFailure(StateError('Signaling connection closed.'));
        }
      },
      cancelOnError: true,
    );
    await channel.ready.timeout(_connectTimeout);
    _sendRaw({
      'type': 'register',
      'protocol': 1,
      'session': credentials.sessionId!,
      'role': role,
    });
    await _registered!.future.timeout(_connectTimeout);
  }

  void _handleMessage(dynamic raw) {
    try {
      if (raw is! String ||
          raw.length > SecureSignalingCodec.maxBodyLength + 2048) {
        throw const FormatException('Invalid signaling frame.');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid signaling JSON.');
      }
      final message = Map<String, dynamic>.from(decoded);
      switch (message['type']) {
        case 'registered':
          _complete(_registered);
        case 'peer_ready':
          final epoch = message['epoch'];
          final credentials = _credentials;
          if (epoch is! String || credentials == null) {
            throw const FormatException('Invalid signaling epoch.');
          }
          _codec = SecureSignalingCodec(
            deriveAudioSessionKey(
              secret: credentials.secret,
              sessionId: credentials.sessionId!,
              epoch: epoch,
            ),
          );
          _hadPeer = true;
          _complete(_peerReady);
          onPeerReady?.call();
        case 'peer_left':
          final notify = _hadPeer;
          _hadPeer = false;
          _codec = null;
          if (notify) onRemoteHangup?.call();
        case 'relay':
          final payload = message['payload'];
          if (payload is! Map || _codec == null) {
            throw const FormatException('Unexpected relay payload.');
          }
          _dispatch(_codec!.decode(Map<String, dynamic>.from(payload)));
        case 'error':
          throw StateError(
            message['message']?.toString() ?? 'Signaling rejected the request.',
          );
        default:
          throw const FormatException('Unknown signaling message.');
      }
    } catch (error) {
      _handleSocketFailure(error);
    }
  }

  void _dispatch(Map<String, dynamic> message) {
    final payload = message['payload'];
    if (message['type'] == 'hangup') {
      onRemoteHangup?.call();
      return;
    }
    if (payload is! Map) throw const FormatException('Invalid relay body.');
    final body = Map<String, dynamic>.from(payload);
    switch (message['type']) {
      case 'offer':
        onOffer?.call(body);
      case 'answer':
        onAnswer?.call(body);
      case 'candidate':
        onCandidate?.call(body);
      case 'control':
        onControl?.call(body);
      default:
        throw const FormatException('Unknown secure message.');
    }
  }

  void _sendSecure(String type, [Map<String, dynamic>? payload]) {
    final codec = _codec;
    if (codec == null) throw StateError('Remote device is not ready.');
    _sendRaw({
      'type': 'relay',
      'payload': codec.encode({'type': type, 'payload': ?payload}),
    });
  }

  void _sendRaw(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) throw StateError('Signaling is disconnected.');
    channel.sink.add(jsonEncode(message));
  }

  @override
  Future<void> sendOffer(Map<String, dynamic> offer) async =>
      _sendSecure('offer', offer);
  @override
  Future<void> sendAnswer(Map<String, dynamic> answer) async =>
      _sendSecure('answer', answer);
  @override
  Future<void> sendControl(Map<String, dynamic> message) async =>
      _sendSecure('control', message);
  @override
  void addCandidate(Map<String, dynamic> candidate) =>
      _sendSecure('candidate', candidate);

  @override
  Future<void> rearmForNewPeer() async {
    if (_role != 'transmitter' || _credentials == null) return;
    await _connectAndRegister();
  }

  @override
  Future<void> hangUp() async {
    if (_closing) return;
    _closing = true;
    try {
      if (_codec != null) {
        try {
          _sendSecure('hangup');
        } catch (_) {}
      }
      await _closeSocket(notifyPeer: false);
      _credentials = null;
      _role = null;
    } finally {
      _closing = false;
    }
  }

  Future<void> _closeSocket({required bool notifyPeer}) async {
    final hadPeer = _hadPeer;
    _hadPeer = false;
    _codec = null;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    try {
      await subscription?.cancel();
      await channel?.sink.close(
        websocket_status.normalClosure,
        'session closed',
      );
    } catch (_) {}
    if (notifyPeer && hadPeer) onRemoteHangup?.call();
  }

  void _handleSocketFailure(Object error) {
    _completeError(_registered, error);
    _completeError(_peerReady, error);
    final notify = !_closing;
    // Detach even when no peer was connected, so a camera can re-register.
    unawaited(_closeSocket(notifyPeer: false));
    if (notify) onRemoteHangup?.call();
  }

  static void _complete(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  static void _completeError(Completer<void>? completer, Object error) {
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }
}
