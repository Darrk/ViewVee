import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_pairing.dart';
import 'audio_signaling.dart';

class LocalAudioSignaling implements AudioSignaling {
  LocalAudioSignaling({MethodChannel? nativeChannel})
    : _nativeChannel =
          nativeChannel ?? const MethodChannel('viewvee/audio_monitor');

  static const _serviceType = '_viewvee._tcp';
  static const _handshakeTimeout = Duration(seconds: 10);
  static const _pingInterval = Duration(seconds: 5);
  static const _pongTimeout = Duration(seconds: 20);

  final MethodChannel _nativeChannel;

  @override
  void Function()? onPeerReady;
  @override
  void Function(Map<String, dynamic>)? onOffer;
  @override
  void Function(Map<String, dynamic>)? onAnswer;
  @override
  void Function(Map<String, dynamic>)? onCandidate;
  @override
  void Function(Map<String, dynamic>)? onControl;
  @override
  void Function()? onRemoteHangup;

  AudioPairingCredentials? _credentials;
  ServerSocket? _server;
  Socket? _peer;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  StreamSubscription<String>? _peerSubscription;
  Timer? _handshakeTimer;
  Timer? _pingTimer;
  Timer? _pongTimer;
  Completer<void>? _clientHandshake;
  SecureSignalingCodec? _codec;
  String? _serverNonce;
  String? _clientNonce;
  String? _expectedServerMac;
  bool _isClient = false;
  bool _authenticated = false;
  bool _multicastLockHeld = false;
  bool _hangingUp = false;

  @override
  String? get roomCode => _credentials?.roomCode;

  @override
  String? get pairingUri => _credentials?.toUriString();

  @override
  Future<String> createRoom() async {
    _credentials = AudioPairingCredentials.generate(
      mode: AudioPairingMode.wifi,
    );
    _isClient = false;
    await _acquireMulticastLock();
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv6,
        0,
        v6Only: false,
      );
    } on SocketException {
      try {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      } on SocketException {
        await _releaseMulticastLock();
        throw StateError('Lokální server nelze spustit. Zkontrolujte Wi-Fi.');
      }
    }
    _server!.listen(_acceptPeer, onError: _logError);
    await _startBroadcast();
    return _credentials!.roomCode;
  }

  Future<void> _startBroadcast() async {
    final server = _server;
    final credentials = _credentials;
    if (server == null || credentials == null) return;
    await _broadcast?.stop();
    _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: 'Viewvee-${credentials.roomCode}',
        type: _serviceType,
        port: server.port,
        attributes: {
          'code': credentials.roomCode,
          'protocol': AudioPairingCredentials.protocolVersion,
        },
      ),
    );
    await _broadcast!.ready;
    await _broadcast!.start();
  }

  void _acceptPeer(Socket socket) {
    if (_peer != null) {
      socket.destroy();
      return;
    }
    _peer = socket;
    _configureSocket(socket);
    _attachSocket(socket);
    _serverNonce = _nonce();
    _sendRaw({'type': 'hello', 'protocol': 1, 'nonce': _serverNonce});
    _armHandshakeTimeout();
  }

  @override
  Future<bool> joinRoom(String pairingValue) async {
    final credentials = AudioPairingCredentials.tryParse(
      pairingValue,
      expectedMode: AudioPairingMode.wifi,
    );
    if (credentials == null) return false;
    _credentials = credentials;
    _isClient = true;
    await _acquireMulticastLock();

    final result = Completer<bool>();
    final timeout = Timer(const Duration(seconds: 30), () {
      if (!result.isCompleted) result.complete(false);
      unawaited(_stopDiscovery());
    });
    _discovery = BonsoirDiscovery(type: _serviceType);
    await _discovery!.ready;
    _discoverySubscription = _discovery!.eventStream!.listen((event) {
      if (result.isCompleted) return;
      if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
        final service = event.service;
        if (service?.name.startsWith('Viewvee-') ?? false) {
          service!.resolve(_discovery!.serviceResolver);
        }
      } else if (event.type ==
          BonsoirDiscoveryEventType.discoveryServiceResolved) {
        final service = event.service as ResolvedBonsoirService;
        final code =
            service.attributes['code'] ??
            service.name.substring(service.name.indexOf('-') + 1);
        if (code == credentials.roomCode) {
          timeout.cancel();
          unawaited(_connectResolved(service, result));
        }
      }
    });
    try {
      await _discovery!.start();
    } catch (error) {
      timeout.cancel();
      await _stopDiscovery();
      if (!result.isCompleted) result.complete(false);
    }
    return result.future;
  }

  Future<void> _connectResolved(
    ResolvedBonsoirService service,
    Completer<bool> result,
  ) async {
    await _stopDiscovery();
    final host = service.host;
    if (host == null || host.isEmpty) {
      if (!result.isCompleted) result.complete(false);
      return;
    }
    try {
      final direct = InternetAddress.tryParse(host);
      final addresses = direct == null
          ? await InternetAddress.lookup(host)
          : [direct];
      final ordered = [
        ...addresses.where((value) => value.type == InternetAddressType.IPv4),
        ...addresses.where((value) => value.type == InternetAddressType.IPv6),
      ];
      for (final address in ordered) {
        try {
          _peer = await Socket.connect(
            address,
            service.port,
            timeout: const Duration(seconds: 10),
          );
          _configureSocket(_peer!);
          _clientHandshake = Completer<void>();
          _armHandshakeTimeout();
          _attachSocket(_peer!);
          try {
            await _clientHandshake!.future;
            if (!result.isCompleted) result.complete(true);
          } catch (error) {
            _logError(error);
            if (!result.isCompleted) result.complete(false);
          }
          return;
        } on SocketException {
          _closePeer();
        }
      }
    } catch (error) {
      _logError(error);
    }
    if (!result.isCompleted) result.complete(false);
  }

  void _configureSocket(Socket socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }

  void _attachSocket(Socket socket) {
    _peerSubscription?.cancel();
    _peerSubscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const _BoundedLineSplitter())
        .listen(
          _handleLine,
          onError: (Object error) => _handlePeerDown(),
          onDone: _handlePeerDown,
          cancelOnError: true,
        );
  }

  void _handleLine(String line) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw const FormatException();
      message = Map<String, dynamic>.from(decoded);
      if (!_authenticated) {
        _handleHandshake(message);
        return;
      }
      message = _codec!.decode(message);
    } on FormatException catch (error) {
      _logError(error);
      _handlePeerDown();
      return;
    }
    switch (message['type']) {
      case 'offer':
        _dispatch(message, onOffer);
      case 'answer':
        _dispatch(message, onAnswer);
      case 'candidate':
        _dispatch(message, onCandidate);
      case 'control':
        _dispatch(message, onControl);
      case 'ping':
        _send({'type': 'pong', 't': message['t']});
      case 'pong':
        _pongTimer?.cancel();
        _pongTimer = null;
      case 'hangup':
        _handlePeerDown();
    }
  }

  void _handleHandshake(Map<String, dynamic> message) {
    final credentials = _credentials;
    if (credentials == null) return _failHandshake('missing credentials');
    switch (message['type']) {
      case 'hello':
        final serverNonce = message['nonce'];
        if (!_isClient ||
            message['protocol'] != 1 ||
            serverNonce is! String ||
            !_validNonce(serverNonce)) {
          return _failHandshake('invalid hello');
        }
        _serverNonce = serverNonce;
        _clientNonce = _nonce();
        _expectedServerMac = computeLocalPairingMac(
          credentials.secret,
          '${_clientNonce!}:$serverNonce',
        );
        _sendRaw({
          'type': 'auth',
          'nonce': _clientNonce,
          'mac': computeLocalPairingMac(
            credentials.secret,
            '$serverNonce:${_clientNonce!}',
          ),
        });
      case 'auth':
        final clientNonce = message['nonce'];
        final clientMac = message['mac'];
        final serverNonce = _serverNonce;
        if (_isClient ||
            clientNonce is! String ||
            clientMac is! String ||
            serverNonce == null ||
            !_validNonce(clientNonce) ||
            !_constantTimeEquals(
              computeLocalPairingMac(
                credentials.secret,
                '$serverNonce:$clientNonce',
              ),
              clientMac,
            )) {
          return _failHandshake('client authentication failed');
        }
        _clientNonce = clientNonce;
        _sendRaw({
          'type': 'auth_ok',
          'mac': computeLocalPairingMac(
            credentials.secret,
            '$clientNonce:$serverNonce',
          ),
        });
        _completeHandshake();
      case 'auth_ok':
        final mac = message['mac'];
        if (!_isClient ||
            mac is! String ||
            _expectedServerMac == null ||
            !_constantTimeEquals(_expectedServerMac!, mac)) {
          return _failHandshake('server authentication failed');
        }
        _completeHandshake();
      default:
        _failHandshake('unexpected handshake message');
    }
  }

  void _completeHandshake() {
    final credentials = _credentials;
    if (credentials == null || _serverNonce == null || _clientNonce == null) {
      return _failHandshake('incomplete key material');
    }
    _codec = SecureSignalingCodec(
      deriveLocalAudioSessionKey(
        secret: credentials.secret,
        serverNonce: _serverNonce!,
        clientNonce: _clientNonce!,
      ),
    );
    _authenticated = true;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _startKeepalive();
    unawaited(_broadcast?.stop());
    onPeerReady?.call();
    final completer = _clientHandshake;
    _clientHandshake = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _armHandshakeTimeout() {
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(_handshakeTimeout, () => _failHandshake('timeout'));
  }

  void _failHandshake(String reason) {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    final completer = _clientHandshake;
    _clientHandshake = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('LAN handshake failed: $reason'));
    }
    _closePeer();
  }

  void _startKeepalive() {
    _stopKeepalive();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _send({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
      _pongTimer ??= Timer(_pongTimeout, _handlePeerDown);
    });
  }

  void _stopKeepalive() {
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _pingTimer = null;
    _pongTimer = null;
  }

  void _dispatch(
    Map<String, dynamic> message,
    void Function(Map<String, dynamic>)? callback,
  ) {
    final payload = message['payload'];
    if (payload is Map) callback?.call(Map<String, dynamic>.from(payload));
  }

  @override
  Future<void> sendOffer(Map<String, dynamic> offer) async {
    _send({'type': 'offer', 'payload': offer});
  }

  @override
  Future<void> sendAnswer(Map<String, dynamic> answer) async {
    _send({'type': 'answer', 'payload': answer});
  }

  @override
  Future<void> sendControl(Map<String, dynamic> message) async {
    _send({'type': 'control', 'payload': message});
  }

  @override
  void addCandidate(Map<String, dynamic> candidate) {
    _send({'type': 'candidate', 'payload': candidate});
  }

  void _send(Map<String, dynamic> message) {
    if (!_authenticated || _codec == null) return;
    _sendRaw(_codec!.encode(message));
  }

  void _sendRaw(Map<String, dynamic> message) {
    try {
      _peer?.write('${jsonEncode(message)}\n');
    } catch (error) {
      _logError(error);
    }
  }

  void _handlePeerDown() {
    if (_peer == null && _peerSubscription == null) return;
    _stopKeepalive();
    _closePeer();
    _authenticated = false;
    _codec = null;
    onRemoteHangup?.call();
  }

  void _closePeer() {
    _peer?.destroy();
    _peer = null;
    _peerSubscription?.cancel();
    _peerSubscription = null;
  }

  @override
  Future<void> rearmForNewPeer() async {
    if (_server == null) return;
    _stopKeepalive();
    _closePeer();
    _authenticated = false;
    _codec = null;
    await _startBroadcast();
  }

  @override
  Future<void> hangUp() async {
    if (_hangingUp) return;
    _hangingUp = true;
    try {
      if (_authenticated) _send({'type': 'hangup'});
      _stopKeepalive();
      _handshakeTimer?.cancel();
      await _broadcast?.stop();
      _broadcast = null;
      await _stopDiscovery();
      _closePeer();
      await _server?.close();
      _server = null;
      await _releaseMulticastLock();
      _authenticated = false;
      _codec = null;
      _credentials = null;
    } finally {
      _hangingUp = false;
    }
  }

  Future<void> _stopDiscovery() async {
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    await _discovery?.stop();
    _discovery = null;
  }

  Future<void> _acquireMulticastLock() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        _multicastLockHeld) {
      return;
    }
    await _nativeChannel.invokeMethod<void>('acquireMulticastLock');
    _multicastLockHeld = true;
  }

  Future<void> _releaseMulticastLock() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_multicastLockHeld) {
      return;
    }
    await _nativeChannel.invokeMethod<void>('releaseMulticastLock');
    _multicastLockHeld = false;
  }

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _validNonce(String value) =>
      RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  static bool _constantTimeEquals(String first, String second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
    }
    return difference == 0;
  }

  static void _logError(Object error) {
    debugPrint('Viewvee LAN signaling: $error');
  }
}

class _BoundedLineSplitter extends StreamTransformerBase<String, String> {
  const _BoundedLineSplitter();

  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buffer = '';
    await for (final chunk in stream) {
      buffer += chunk;
      var newline = buffer.indexOf('\n');
      while (newline >= 0) {
        final line = buffer.substring(0, newline);
        if (line.length > SecureSignalingCodec.maxBodyLength + 1024) {
          throw const FormatException('Signaling line is too large.');
        }
        yield line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
        buffer = buffer.substring(newline + 1);
        newline = buffer.indexOf('\n');
      }
      if (buffer.length > SecureSignalingCodec.maxBodyLength + 1024) {
        throw const FormatException('Signaling line is too large.');
      }
    }
  }
}
