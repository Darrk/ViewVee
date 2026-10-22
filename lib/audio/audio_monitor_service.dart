import 'dart:async';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'audio_signaling.dart';
import 'frame_motion_detector.dart';
import 'internet_audio_signaling.dart';
import 'local_audio_signaling.dart';
import 'turn_credentials_service.dart';

enum AudioMonitorRole { transmitter, receiver }

enum AudioConnectionMode { wifi, internet }

enum MonitorSignalQuality { unknown, weak, good, excellent }

enum MonitorDetectionEvent { motion, sound }

class MonitorTelemetry {
  const MonitorTelemetry({
    this.batteryLevel,
    this.signalQuality = MonitorSignalQuality.unknown,
    this.soundLevel = 0,
  });

  final int? batteryLevel;
  final MonitorSignalQuality signalQuality;
  final double soundLevel;

  MonitorTelemetry copyWith({
    int? batteryLevel,
    MonitorSignalQuality? signalQuality,
    double? soundLevel,
  }) => MonitorTelemetry(
    batteryLevel: batteryLevel ?? this.batteryLevel,
    signalQuality: signalQuality ?? this.signalQuality,
    soundLevel: soundLevel ?? this.soundLevel,
  );
}

enum AudioConnectionState {
  idle,
  creatingRoom,
  waitingForPeer,
  connecting,
  connected,
  disconnected,
  error,
}

class AudioMonitorService {
  AudioMonitorService({
    AudioSignaling? signaling,
    TurnCredentialsService? turnCredentials,
    AudioConnectionMode mode = AudioConnectionMode.internet,
  }) : _mode = mode,
       _turnCredentials = turnCredentials ?? TurnCredentialsService(),
       _signaling =
           signaling ??
           switch (mode) {
             AudioConnectionMode.wifi => LocalAudioSignaling(),
             AudioConnectionMode.internet => InternetAudioSignaling(
               serverUri: Uri.parse(
                 const String.fromEnvironment(
                   'VIEWVEE_SIGNALING_URL',
                   defaultValue: 'wss://signal.viewvee.com/viewvee/ws',
                 ),
               ),
             ),
           };

  final AudioSignaling _signaling;
  final AudioConnectionMode _mode;
  final TurnCredentialsService _turnCredentials;
  static const _nativeChannel = MethodChannel('viewvee/audio_monitor');
  RTCPeerConnection? _peerConnection;
  Future<RTCPeerConnection>? _creatingConnection;
  int _connectionGeneration = 0;
  MediaStream? _localStream;
  MediaStream? _talkbackStream;
  RTCRtpSender? _talkbackSender;
  RTCVideoRenderer? _localVideoRenderer;
  RTCVideoRenderer? _remoteAudioRenderer;
  RTCVideoRenderer? _remoteVideoRenderer;
  MediaRecorder? _mediaRecorder;
  AudioMonitorRole? _role;
  AudioConnectionState _state = AudioConnectionState.idle;
  bool _peerReady = false;
  bool _initialOfferSent = false;
  bool _remoteDescriptionSet = false;
  bool _changingTalkback = false;
  bool _talkbackEnabled = false;
  bool _transmitterIsHd = false;
  bool _stopping = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  static const _reconnectBackoff = Duration(seconds: 3);
  String? _lastPairingValue;
  Timer? _reconnectTimer;
  Timer? _negotiationTimer;
  int _reconnectAttempts = 0;
  bool _sessionActive = false;
  int _sessionGeneration = 0;
  bool _reconnecting = false;
  final Battery _battery = Battery();
  final FrameMotionDetector _motionDetector = FrameMotionDetector();
  Timer? _monitorTimer;
  bool _monitorTickRunning = false;
  int _monitorTickCount = 0;
  bool _motionDetectionEnabled = true;
  bool _soundDetectionEnabled = true;
  int _detectionSensitivity = 1;
  DateTime? _lastMotionEvent;
  DateTime? _lastSoundEvent;
  MonitorTelemetry _telemetry = const MonitorTelemetry();

  void Function(AudioConnectionState state)? onStateChanged;
  void Function()? onRemoteHangup;
  void Function(Object error)? onError;
  void Function(MonitorTelemetry telemetry)? onTelemetry;
  void Function(MonitorDetectionEvent event)? onDetection;

  AudioConnectionState get state => _state;
  String? get roomCode => _signaling.roomCode;
  String? get pairingUri => _signaling.pairingUri;
  bool get isTalkbackEnabled => _talkbackEnabled;
  RTCVideoRenderer? get localVideoRenderer => _localVideoRenderer;
  RTCVideoRenderer? get remoteVideoRenderer => _remoteVideoRenderer;
  MonitorTelemetry get telemetry => _telemetry;
  bool get isRecording => _mediaRecorder != null;
  bool get canRecord {
    final stream = _role == AudioMonitorRole.transmitter
        ? _localStream
        : _remoteVideoRenderer?.srcObject;
    return stream?.getVideoTracks().isNotEmpty ?? false;
  }

  Future<String> startTransmitter({bool isHd = false}) async {
    await _prepare(AudioMonitorRole.transmitter);
    _transmitterIsHd = isHd;
    _setState(AudioConnectionState.creatingRoom);
    try {
      _sessionActive = true;
      _reconnectAttempts = 0;
      _configureSignaling();
      final code = await _signaling.createRoom();
      _peerConnection = await _createConnection();
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints(AudioMonitorRole.transmitter),
        'video': _videoConstraints(isHd: isHd, useFrontCamera: false),
      });
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      _localVideoRenderer = RTCVideoRenderer();
      await _localVideoRenderer!.initialize();
      _localVideoRenderer!.srcObject = _localStream;
      await _startForegroundService('transmitter');
      _setState(AudioConnectionState.waitingForPeer);
      await _sendInitialOfferIfReady();
      return code;
    } catch (error) {
      await _fail(error);
      rethrow;
    }
  }

  Future<bool> joinAsReceiver(String pairingValue) async {
    await _prepare(AudioMonitorRole.receiver);
    _setState(AudioConnectionState.connecting);
    try {
      _sessionActive = true;
      _lastPairingValue = pairingValue;
      _reconnectAttempts = 0;
      _configureSignaling();
      final joined = await _signaling
          .joinRoom(pairingValue)
          .timeout(const Duration(seconds: 45));
      if (!joined) {
        await _fail(StateError('Relace nebyla nalezena.'));
        return false;
      }
      _peerConnection ??= await _createConnection();
      await _startForegroundService('receiver');
      _watchNegotiation();
      return true;
    } catch (error) {
      await _fail(error);
      rethrow;
    }
  }

  Future<void> _prepare(AudioMonitorRole role) async {
    if (_state != AudioConnectionState.idle) await stop();
    _role = role;
    _peerReady = false;
    _initialOfferSent = false;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    await WebRTC.initialize(options: const {});
  }

  void _configureSignaling() {
    _signaling.onPeerReady = () {
      _peerReady = true;
      unawaited(_sendInitialOfferIfReady());
    };
    _signaling.onOffer = (offer) => unawaited(_handleOffer(offer));
    _signaling.onAnswer = (answer) => unawaited(_handleAnswer(answer));
    _signaling.onCandidate = (candidate) =>
        unawaited(_handleCandidate(candidate));
    _signaling.onControl = _handleControl;
    _signaling.onRemoteHangup = () {
      _setState(AudioConnectionState.disconnected);
      onRemoteHangup?.call();
      _scheduleReconnect();
    };
  }

  Future<RTCPeerConnection> _createConnection() async {
    // Joining a room and receiving its offer can race while credentials load.
    final pending = _creatingConnection;
    if (pending != null) return pending;
    final creation = _creatingConnection = _buildConnection();
    try {
      return await creation;
    } finally {
      if (identical(_creatingConnection, creation)) _creatingConnection = null;
    }
  }

  Future<RTCPeerConnection> _buildConnection() async {
    final generation = _connectionGeneration;
    final servers = await _iceServers();
    if (generation != _connectionGeneration) {
      throw StateError('Connection creation was cancelled.');
    }
    final connection = await createPeerConnection({
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
    });
    if (generation != _connectionGeneration) {
      await connection.close();
      throw StateError('Connection creation was cancelled.');
    }
    connection.onIceCandidate = (candidate) {
      if (generation != _connectionGeneration) return;
      if (candidate.candidate == null) return;
      _signaling.addCandidate({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    connection.onTrack = (event) {
      if (generation == _connectionGeneration) {
        unawaited(_handleRemoteTrack(event));
      }
    };
    connection.onConnectionState = (connectionState) {
      if (generation != _connectionGeneration) return;
      switch (connectionState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(AudioConnectionState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setState(AudioConnectionState.disconnected);
          _scheduleReconnect();
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (!_stopping) _setState(AudioConnectionState.disconnected);
        default:
          break;
      }
    };
    return connection;
  }

  Future<List<Map<String, dynamic>>> _iceServers() async {
    if (_mode == AudioConnectionMode.wifi) return [];
    final servers = <Map<String, dynamic>>[
      {
        'urls': const String.fromEnvironment(
          'VIEWVEE_STUN_URLS',
          defaultValue:
              'stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302',
        ).split(','),
      },
    ];
    // New connections and reconnects obtain fresh credentials. Existing
    // allocations are refreshed by WebRTC without interrupting active media.
    final credentials = await _turnCredentials.fetch();
    if (credentials != null) servers.add(credentials.toIceServer());
    return servers;
  }

  Future<void> _sendInitialOfferIfReady() async {
    if (_role != AudioMonitorRole.transmitter ||
        !_peerReady ||
        _initialOfferSent ||
        _peerConnection == null ||
        _localStream == null) {
      return;
    }
    _initialOfferSent = true;
    try {
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      await _signaling.sendOffer(_descriptionMap(offer));
      _setState(AudioConnectionState.connecting);
      _watchNegotiation();
    } catch (error) {
      _initialOfferSent = false;
      onError?.call(error);
      _scheduleReconnect();
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> value) async {
    try {
      _peerConnection ??= await _createConnection();
      final offer = RTCSessionDescription(
        value['sdp'] as String?,
        value['type'] as String?,
      );
      await _peerConnection!.setRemoteDescription(offer);
      _remoteDescriptionSet = true;
      await _flushCandidates();
      final answer = await _peerConnection!.createAnswer();
      await _peerConnection!.setLocalDescription(answer);
      await _signaling.sendAnswer(_descriptionMap(answer));
    } catch (error) {
      await _fail(error);
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> value) async {
    try {
      final connection = _peerConnection;
      if (connection == null) return;
      await connection.setRemoteDescription(
        RTCSessionDescription(
          value['sdp'] as String?,
          value['type'] as String?,
        ),
      );
      _remoteDescriptionSet = true;
      await _flushCandidates();
    } catch (error) {
      await _fail(error);
    }
  }

  Future<void> _handleCandidate(Map<String, dynamic> value) async {
    final candidate = RTCIceCandidate(
      value['candidate'] as String?,
      value['sdpMid'] as String?,
      value['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet || _peerConnection == null) {
      if (_pendingCandidates.length < 256) _pendingCandidates.add(candidate);
      return;
    }
    await _peerConnection!.addCandidate(candidate);
  }

  Future<void> _flushCandidates() async {
    final connection = _peerConnection;
    if (connection == null) return;
    for (final candidate in List<RTCIceCandidate>.from(_pendingCandidates)) {
      await connection.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _handleRemoteTrack(RTCTrackEvent event) async {
    if (event.streams.isEmpty) return;
    if (event.track.kind == 'video') {
      final renderer = _remoteVideoRenderer ?? RTCVideoRenderer();
      if (_remoteVideoRenderer == null) {
        await renderer.initialize();
        _remoteVideoRenderer = renderer;
      }
      renderer.srcObject = event.streams.first;
      return;
    }
    if (event.track.kind != 'audio') return;
    final renderer = _remoteAudioRenderer ?? RTCVideoRenderer();
    if (_remoteAudioRenderer == null) {
      await renderer.initialize();
      _remoteAudioRenderer = renderer;
    }
    renderer.srcObject = event.streams.first;
    if (!kIsWeb) await Helper.setSpeakerphoneOn(true);
  }

  void setTransmitterMuted(bool muted) {
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  void setReceiverMuted(bool muted) {
    for (final track
        in _remoteAudioRenderer?.srcObject?.getAudioTracks() ??
            <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  Future<void> setVideoQuality({required bool isHd}) async {
    _transmitterIsHd = isHd;
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await tracks.first.applyConstraints({
      'width': {'ideal': isHd ? 1280 : 640},
      'height': {'ideal': isHd ? 720 : 480},
      'frameRate': {'ideal': isHd ? 24 : 15, 'max': 30},
    });
  }

  Future<bool> setTorchEnabled(bool enabled) async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return false;
    try {
      final track = tracks.first;
      if (!await track.hasTorch()) return false;
      await track.setTorch(enabled);
      return true;
    } on PlatformException catch (error) {
      debugPrint('ViewVee torch control: $error');
      return false;
    }
  }

  Future<bool> setNightModeEnabled(bool enabled) async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return false;
    final track = tracks.first;
    try {
      await Helper.setExposureMode(track, CameraExposureMode.auto);
    } on PlatformException catch (error) {
      debugPrint('ViewVee exposure mode: $error');
    }
    try {
      await track.applyConstraints({
        'frameRate': {'ideal': enabled ? 15 : 24, 'max': enabled ? 20 : 30},
        'advanced': [
          {
            'exposureMode': 'continuous',
            'exposureCompensation': enabled ? 1.5 : 0.0,
          },
        ],
      });
    } on PlatformException catch (error) {
      debugPrint('ViewVee night constraints: $error');
    }
    return true;
  }

  Future<void> startRecording(String path) async {
    if (_mediaRecorder != null) {
      throw StateError('Nahrávání už probíhá.');
    }
    final stream = _role == AudioMonitorRole.transmitter
        ? _localStream
        : _remoteVideoRenderer?.srcObject;
    final tracks = stream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      throw StateError('Video zatím není dostupné pro nahrávání.');
    }
    final recorder = MediaRecorder(albumName: 'ViewVee');
    try {
      await recorder.start(
        path,
        videoTrack: tracks.first,
        audioChannel: _role == AudioMonitorRole.transmitter
            ? RecorderAudioChannel.INPUT
            : RecorderAudioChannel.OUTPUT,
      );
      _mediaRecorder = recorder;
    } catch (_) {
      _mediaRecorder = null;
      rethrow;
    }
  }

  Future<void> stopRecording() async {
    final recorder = _mediaRecorder;
    if (recorder == null) return;
    _mediaRecorder = null;
    await recorder.stop();
  }

  Future<void> configureDetection({
    required bool motionEnabled,
    required bool soundEnabled,
    required int sensitivity,
  }) async {
    _motionDetectionEnabled = motionEnabled;
    _soundDetectionEnabled = soundEnabled;
    _detectionSensitivity = sensitivity.clamp(0, 2);
    if (_role == AudioMonitorRole.receiver &&
        _state == AudioConnectionState.connected) {
      await _sendControl({
        'kind': 'detection_config',
        'motion': motionEnabled,
        'sound': soundEnabled,
        'sensitivity': _detectionSensitivity,
      });
    }
  }

  Future<void> setTalkbackEnabled(bool enabled) async {
    if (_changingTalkback || enabled == _talkbackEnabled) return;
    if (_role != AudioMonitorRole.receiver ||
        _state != AudioConnectionState.connected ||
        _peerConnection == null) {
      throw StateError('Talkback vyžaduje aktivní spojení.');
    }
    _changingTalkback = true;
    try {
      if (!enabled) {
        for (final track
            in _talkbackStream?.getTracks() ?? <MediaStreamTrack>[]) {
          track.stop();
        }
        await _talkbackStream?.dispose();
        _talkbackStream = null;
        await _talkbackSender?.replaceTrack(null);
        _talkbackEnabled = false;
        return;
      }
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints(AudioMonitorRole.receiver),
        'video': false,
      });
      final track = stream.getAudioTracks().first;
      if (_talkbackSender == null) {
        _talkbackSender = await _peerConnection!.addTrack(track, stream);
      } else {
        await _talkbackSender!.replaceTrack(track);
      }
      _talkbackStream = stream;
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);
      _remoteDescriptionSet = false;
      await _signaling.sendOffer(_descriptionMap(offer));
      await _startForegroundService('receiverTalkback');
      _talkbackEnabled = true;
    } finally {
      _changingTalkback = false;
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _sessionGeneration++;
    _connectionGeneration++;
    _creatingConnection = null;
    try {
      try {
        await stopRecording();
      } catch (_) {}
      _sessionActive = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _negotiationTimer?.cancel();
      _negotiationTimer = null;
      _reconnectAttempts = 0;
      _reconnecting = false;
      _stopMonitoring();
      for (final stream in [_localStream, _talkbackStream]) {
        for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
          track.stop();
        }
        await stream?.dispose();
      }
      _localStream = null;
      _talkbackStream = null;
      _talkbackSender = null;
      try {
        await _peerConnection?.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
      _peerConnection = null;
      try {
        _localVideoRenderer?.srcObject = null;
        await _localVideoRenderer?.dispose();
      } catch (_) {}
      _localVideoRenderer = null;
      try {
        _remoteAudioRenderer?.srcObject = null;
        await _remoteAudioRenderer?.dispose();
      } catch (_) {}
      _remoteAudioRenderer = null;
      try {
        _remoteVideoRenderer?.srcObject = null;
        await _remoteVideoRenderer?.dispose();
      } catch (_) {}
      _remoteVideoRenderer = null;
      await _stopForegroundService();
      await _signaling.hangUp();
      _role = null;
      _lastPairingValue = null;
      _talkbackEnabled = false;
      _pendingCandidates.clear();
      _telemetry = const MonitorTelemetry();
      _setState(AudioConnectionState.idle);
    } finally {
      _stopping = false;
    }
  }

  Future<void> _fail(Object error) async {
    onError?.call(error);
    _setState(AudioConnectionState.error);
    _scheduleReconnect();
  }

  void _watchNegotiation() {
    _negotiationTimer?.cancel();
    if (_state == AudioConnectionState.connected) return;
    _negotiationTimer = Timer(const Duration(seconds: 30), () {
      if (!_sessionActive ||
          _stopping ||
          _state == AudioConnectionState.connected) {
        return;
      }
      _setState(AudioConnectionState.disconnected);
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (!_sessionActive || _stopping || _reconnecting) return;
    if (_reconnectTimer?.isActive ?? false) return;
    final delay = _reconnectBackoff * (_reconnectAttempts + 1).clamp(1, 5);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_reconnect());
    });
  }

  Future<void> _reconnect() async {
    if (!_sessionActive || _stopping || _reconnecting || _role == null) return;
    final generation = _sessionGeneration;
    bool current() =>
        generation == _sessionGeneration && _sessionActive && !_stopping;
    _reconnecting = true;
    _reconnectAttempts += 1;
    _negotiationTimer?.cancel();
    _setState(AudioConnectionState.connecting);
    try {
      if (_role == AudioMonitorRole.transmitter && _localStream == null) {
        await startTransmitter(isHd: _transmitterIsHd);
        return;
      }
      _peerReady = false;
      _initialOfferSent = false;
      _remoteDescriptionSet = false;
      _pendingCandidates.clear();
      await _resetPeerConnection(keepLocalStream: true);
      if (!current() || _role == null) return;
      _configureSignaling();

      if (_role == AudioMonitorRole.transmitter) {
        _peerConnection = await _createConnection();
        if (!current()) return;
        final stream = _localStream;
        if (stream == null) throw StateError('Kamera již není dostupná.');
        for (final track in stream.getTracks()) {
          await _peerConnection!.addTrack(track, stream);
        }
        if (!_peerReady) await _signaling.rearmForNewPeer();
        if (!current()) return;
        if (!_initialOfferSent && _state != AudioConnectionState.connected) {
          _setState(AudioConnectionState.waitingForPeer);
        }
        await _sendInitialOfferIfReady();
      } else {
        final pairingValue = _lastPairingValue;
        if (pairingValue == null) throw StateError('Chybí párovací údaje.');
        await _signaling.hangUp();
        if (!current()) return;
        _configureSignaling();
        final joined = await _signaling
            .joinRoom(pairingValue)
            .timeout(const Duration(seconds: 45));
        if (!current()) return;
        if (!joined) throw StateError('Kamera nebyla nalezena.');
        _peerConnection ??= await _createConnection();
        _watchNegotiation();
      }
    } catch (error) {
      if (!current()) return;
      onError?.call(error);
      _setState(AudioConnectionState.disconnected);
    } finally {
      if (generation == _sessionGeneration) {
        _reconnecting = false;
        if (_state == AudioConnectionState.disconnected ||
            _state == AudioConnectionState.error) {
          _scheduleReconnect();
        }
      }
    }
  }

  Future<void> _resetPeerConnection({required bool keepLocalStream}) async {
    _connectionGeneration++;
    _creatingConnection = null;
    final previous = _peerConnection;
    _peerConnection = null;
    try {
      await previous?.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!keepLocalStream) {
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      await _localStream?.dispose();
      _localStream = null;
    }
  }

  void _setState(AudioConnectionState value) {
    if (_state == value) return;
    _state = value;
    if (value == AudioConnectionState.connected) {
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _negotiationTimer?.cancel();
      _startMonitoring();
      if (_role == AudioMonitorRole.receiver) {
        unawaited(
          configureDetection(
            motionEnabled: _motionDetectionEnabled,
            soundEnabled: _soundDetectionEnabled,
            sensitivity: _detectionSensitivity,
          ),
        );
      }
    } else if (value == AudioConnectionState.disconnected ||
        value == AudioConnectionState.error ||
        value == AudioConnectionState.idle) {
      _stopMonitoring();
    }
    onStateChanged?.call(value);
  }

  void _startMonitoring() {
    _monitorTimer?.cancel();
    _monitorTickCount = 0;
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_monitorTick());
    });
    unawaited(_monitorTick());
  }

  void _stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _motionDetector.reset();
  }

  Future<void> _monitorTick() async {
    if (_monitorTickRunning ||
        _state != AudioConnectionState.connected ||
        _peerConnection == null) {
      return;
    }
    _monitorTickRunning = true;
    try {
      final reports = await _peerConnection!.getStats();
      if (_role == AudioMonitorRole.receiver) {
        _updateTelemetry(
          _telemetry.copyWith(signalQuality: _signalQuality(reports)),
        );
        return;
      }

      final soundLevel = _soundLevel(reports);
      int? batteryLevel;
      if (_monitorTickCount % 15 == 0) {
        batteryLevel = await _battery.batteryLevel;
      }
      _monitorTickCount += 1;
      await _sendControl({
        'kind': 'telemetry',
        'battery': ?batteryLevel,
        'soundLevel': soundLevel,
      });
      if (_soundDetectionEnabled &&
          soundLevel >= _soundThreshold &&
          _cooldownElapsed(_lastSoundEvent)) {
        _lastSoundEvent = DateTime.now();
        await _sendControl({'kind': 'event', 'event': 'sound'});
      }
      if (_motionDetectionEnabled) await _detectMotion();
    } catch (error) {
      debugPrint('Viewvee monitoring tick: $error');
    } finally {
      _monitorTickRunning = false;
    }
  }

  Future<void> _detectMotion() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    final ByteBuffer frame = await tracks.first.captureFrame();
    if (_motionDetector.addFrame(
          frame.asUint8List(),
          sensitivity: _detectionSensitivity,
        ) &&
        _cooldownElapsed(_lastMotionEvent)) {
      _lastMotionEvent = DateTime.now();
      await _sendControl({'kind': 'event', 'event': 'motion'});
    }
  }

  void _handleControl(Map<String, dynamic> message) {
    switch (message['kind']) {
      case 'detection_config':
        if (_role != AudioMonitorRole.transmitter) return;
        _motionDetectionEnabled = message['motion'] == true;
        _soundDetectionEnabled = message['sound'] == true;
        final sensitivity = message['sensitivity'];
        if (sensitivity is int) {
          _detectionSensitivity = sensitivity.clamp(0, 2);
        }
      case 'telemetry':
        if (_role != AudioMonitorRole.receiver) return;
        final battery = message['battery'];
        final sound = message['soundLevel'];
        _updateTelemetry(
          _telemetry.copyWith(
            batteryLevel: battery is int ? battery.clamp(0, 100) : null,
            soundLevel: sound is num ? sound.toDouble().clamp(0, 1) : null,
          ),
        );
      case 'event':
        if (_role != AudioMonitorRole.receiver) return;
        switch (message['event']) {
          case 'motion':
            onDetection?.call(MonitorDetectionEvent.motion);
          case 'sound':
            onDetection?.call(MonitorDetectionEvent.sound);
        }
    }
  }

  Future<void> _sendControl(Map<String, dynamic> message) async {
    try {
      await _signaling.sendControl(message);
    } catch (error) {
      debugPrint('Viewvee control message: $error');
    }
  }

  void _updateTelemetry(MonitorTelemetry value) {
    _telemetry = value;
    onTelemetry?.call(value);
  }

  double get _soundThreshold => switch (_detectionSensitivity) {
    0 => 0.65,
    1 => 0.4,
    _ => 0.2,
  };

  static bool _cooldownElapsed(DateTime? lastEvent) =>
      lastEvent == null ||
      DateTime.now().difference(lastEvent) >= const Duration(seconds: 30);

  static double _soundLevel(List<StatsReport> reports) {
    var level = 0.0;
    for (final report in reports) {
      final raw = report.values['audioLevel'];
      if (raw is num) level = raw.toDouble().clamp(level, 1.0);
    }
    return level;
  }

  static MonitorSignalQuality _signalQuality(List<StatsReport> reports) {
    var roundTripTime = 1.0;
    var packetsLost = 0;
    var packetsReceived = 0;
    for (final report in reports) {
      if (report.type == 'candidate-pair' &&
          (report.values['nominated'] == true ||
              report.values['selected'] == true)) {
        final rawRtt = report.values['currentRoundTripTime'];
        if (rawRtt is num) roundTripTime = rawRtt.toDouble();
      }
      if (report.type == 'inbound-rtp') {
        final lost = report.values['packetsLost'];
        final received = report.values['packetsReceived'];
        if (lost is num) packetsLost += lost.toInt();
        if (received is num) packetsReceived += received.toInt();
      }
    }
    final total = packetsLost + packetsReceived;
    final loss = total == 0 ? 0.0 : packetsLost / total;
    if (roundTripTime <= 0.15 && loss < 0.02) {
      return MonitorSignalQuality.excellent;
    }
    if (roundTripTime <= 0.4 && loss < 0.08) {
      return MonitorSignalQuality.good;
    }
    return MonitorSignalQuality.weak;
  }

  static Map<String, dynamic> _descriptionMap(RTCSessionDescription value) => {
    'sdp': value.sdp,
    'type': value.type,
  };

  static Map<String, dynamic> _audioConstraints(AudioMonitorRole role) => {
    'mandatory': {
      'googEchoCancellation': true,
      'googNoiseSuppression': role == AudioMonitorRole.receiver,
      'googAutoGainControl': true,
      'googHighpassFilter': false,
    },
    'optional': <Map<String, dynamic>>[],
  };

  static Map<String, dynamic> _videoConstraints({
    required bool isHd,
    required bool useFrontCamera,
  }) => {
    'facingMode': useFrontCamera ? 'user' : 'environment',
    'width': {'ideal': isHd ? 1280 : 640},
    'height': {'ideal': isHd ? 720 : 480},
    'frameRate': {'ideal': isHd ? 24 : 15, 'max': 30},
  };

  Future<void> backgroundCamera() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Background camera requires Android.');
    }
    if (_role != AudioMonitorRole.transmitter ||
        _localStream == null ||
        (_state != AudioConnectionState.waitingForPeer &&
            _state != AudioConnectionState.connected)) {
      throw StateError('Start the camera before running in the background.');
    }
    await _nativeChannel.invokeMethod<void>('backgroundCamera');
  }

  Future<void> _startForegroundService(String role) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _nativeChannel.invokeMethod<void>('startForegroundService', {
        'role': role,
      });
    } on PlatformException {
      // WebRTC remains usable in foreground if the OS service cannot start.
    }
  }

  Future<void> _stopForegroundService() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _nativeChannel.invokeMethod<void>('stopForegroundService');
    } on PlatformException {
      // Best-effort cleanup during teardown.
    }
  }
}
