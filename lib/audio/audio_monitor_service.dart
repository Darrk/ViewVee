import '../monitor/device_limits.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'audio_signaling.dart';
import 'audio_pairing.dart';
import 'camera_pairing_repository.dart';
import 'camera_video_controller.dart';
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
    AudioSignaling Function()? signalingFactory,
    CameraPairingRepository? pairingRepository,
    this.manageForegroundService = true,
    bool isPremium = false,
    AudioConnectionMode mode = AudioConnectionMode.internet,
    // Keep entitlement changes behind setPremiumEnabled so child sessions follow.
    // ignore: prefer_initializing_formals
  }) : _isPremium = isPremium,
       _mode = mode,
       _turnCredentials = turnCredentials ?? TurnCredentialsService(),
       _pairingRepository =
           pairingRepository ??
           (signaling == null && signalingFactory == null
               ? CameraPairingRepository()
               : null),
       _signalingFactory = signalingFactory ?? (() => _createSignaling(mode)),
       _signaling =
           signaling ?? signalingFactory?.call() ?? _createSignaling(mode);

  static AudioSignaling _createSignaling(AudioConnectionMode mode) =>
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

  bool _isPremium;
  void setPremiumEnabled(bool enabled) {
    if (_isPremium == enabled) return;
    _isPremium = enabled;
    if (!enabled && _additionalMonitors.isNotEmpty) {
      final extra = _additionalMonitors.toList();
      _additionalMonitors.clear();
      for (final session in extra) {
        session.onStateChanged = null;
        session.onRemoteHangup = null;
        unawaited(session.stop());
      }
    }
    if (_role == AudioMonitorRole.receiver) {
      unawaited(setReceiverViewing(_receiverViewing));
    }
    for (final session in _additionalMonitors) {
      session.setPremiumEnabled(enabled);
    }
  }

  void _requirePremium() {
    if (!_isPremium) throw StateError('Tato funkce vyžaduje Premium.');
  }

  final AudioConnectionMode _mode;
  final CameraPairingRepository? _pairingRepository;
  final AudioSignaling Function() _signalingFactory;
  final List<AudioMonitorService> _additionalMonitors = [];
  bool _ownsLocalStream = true;
  bool _hasConnectedOnce = false;
  AudioMonitorService? _cameraOwner;
  RTCRtpSender? _videoSender;
  Future<CameraMonitorPairing>? _creatingMonitorPairing;

  final AudioSignaling _signaling;
  final bool manageForegroundService;
  bool _receiverViewing = true;
  bool _appBackgrounded = false;
  bool _viewerVideoEnabled = true;
  bool _remoteVideoPaused = false;
  bool get isRemoteVideoPaused => _remoteVideoPaused;
  bool get _cameraBackgrounded => (_cameraOwner ?? this)._appBackgrounded;
  bool _receiverMuted = false;
  bool get isReceiverMuted => _receiverMuted;
  bool _viewerActive = true;
  bool _viewerHdAllowed = true;
  Future<void> _viewerUpdate = Future<void>.value();
  final TurnCredentialsService _turnCredentials;
  static const _nativeChannel = MethodChannel('viewvee/audio_monitor');
  RTCPeerConnection? _peerConnection;
  Future<RTCPeerConnection>? _creatingConnection;
  int _connectionGeneration = 0;
  MediaStream? _localStream;
  CameraVideoController? _cameraVideo;
  bool _isHd = false;
  bool _nightMode = false;
  bool _torchEnabled = false;
  int _cameraRequestId = 0;
  final Map<int, Completer<bool>> _cameraRequests = {};
  Future<void>? _cameraCommands;
  MediaStream? _talkbackStream;
  RTCRtpSender? _talkbackSender;
  RTCVideoRenderer? _localVideoRenderer;
  RTCVideoRenderer? _remoteAudioRenderer;
  RTCVideoRenderer? _remoteVideoRenderer;
  MediaRecorder? _mediaRecorder;
  bool _recordingStarting = false;
  Future<void>? _pendingRecordingStart;
  Future<void>? _pendingRecordingStop;
  bool get _recordingNeedsVideo => _recordingStarting || _mediaRecorder != null;
  AudioMonitorRole? _role;
  AudioConnectionState _state = AudioConnectionState.idle;
  bool _peerReady = false;
  bool _initialOfferSent = false;
  bool _remoteDescriptionSet = false;
  bool _changingTalkback = false;
  bool _talkbackEnabled = false;
  bool _stopping = false;
  final List<RTCIceCandidate> _pendingCandidates = [];
  static const _reconnectBackoff = Duration(seconds: 3);
  String? _lastPairingValue;
  Timer? _reconnectTimer;
  Timer? _negotiationTimer;
  Timer? _reconnectTimeoutTimer;
  bool _autoReconnectEnabled = true;
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
  void Function(AudioConnectionState state)? onConnectionStateObserved;
  void Function()? onRemoteHangup;
  void Function(Object error)? onError;
  void Function(MonitorTelemetry telemetry)? onTelemetry;
  void Function(MonitorDetectionEvent event)? onDetection;
  void Function()? onVideoSettingsChanged;

  bool get isHd => _isHd;
  bool get nightMode => _nightMode;
  bool get torchEnabled => _torchEnabled;
  bool get isFrontCamera =>
      (_cameraOwner ?? this)._cameraVideo?.useFrontCamera ?? false;

  AudioConnectionState get state =>
      connectedMonitorCount > 0 ? AudioConnectionState.connected : _state;

  int get connectedMonitorCount => _role == AudioMonitorRole.transmitter
      ? (_state == AudioConnectionState.connected ? 1 : 0) +
            _additionalMonitors
                .where(
                  (session) => session._state == AudioConnectionState.connected,
                )
                .length
      : 0;

  bool get canAddMonitor =>
      _canHostMonitors &&
      (_additionalMonitors.length + 1 < DeviceLimits.monitors ||
          _unusedMonitorInvitation != null);

  AudioMonitorService? get _unusedMonitorInvitation =>
      [this, ..._additionalMonitors]
          .where(
            (session) =>
                !session._hasConnectedOnce &&
                session._state == AudioConnectionState.waitingForPeer &&
                session.pairingUri != null &&
                session.roomCode != null,
          )
          .firstOrNull;

  bool get _canHostMonitors =>
      _role == AudioMonitorRole.transmitter &&
      _ownsLocalStream &&
      _sessionActive &&
      !_stopping &&
      _localStream != null;

  Iterable<RTCRtpSender> _cameraSenders() sync* {
    if (_videoSender != null) yield _videoSender!;
    for (final session in _additionalMonitors) {
      if (session._videoSender != null) yield session._videoSender!;
    }
  }

  /// Each viewer has its own authenticated signaling room and WebRTC sender.
  /// Unused invitations are reused, so opening the sheet does not leak rooms.
  Future<CameraMonitorPairing> createMonitorPairing() {
    return _creatingMonitorPairing ??= _createMonitorPairing().whenComplete(() {
      _creatingMonitorPairing = null;
    });
  }

  Future<CameraMonitorPairing> _createMonitorPairing() async {
    _requirePremium();
    if (!_canHostMonitors) throw StateError('Nejprve spusťte kameru.');
    final generation = _sessionGeneration;
    await _cameraVideo?.settled;
    if (!_canHostMonitors || generation != _sessionGeneration) {
      throw StateError('Kamera již není dostupná.');
    }
    final unused = _unusedMonitorInvitation;
    if (unused != null) {
      return CameraMonitorPairing(unused.roomCode!, unused.pairingUri!);
    }
    return _openMonitorPairing();
  }

  Future<CameraMonitorPairing> _openMonitorPairing({
    AudioPairingCredentials? credentials,
  }) async {
    if (_additionalMonitors.length + 1 >= DeviceLimits.monitors) {
      throw StateError(DeviceLimits.monitorLimitMessage);
    }
    final generation = _sessionGeneration;
    final session = AudioMonitorService(
      signalingFactory: _signalingFactory,
      turnCredentials: _turnCredentials,
      isPremium: _isPremium,
      mode: _mode,
    );
    session._ownsLocalStream = false;
    session._cameraOwner = this;
    session.setAutoReconnectEnabled(_autoReconnectEnabled);
    session.onStateChanged = (_) {
      if (!_stopping) onStateChanged?.call(state);
    };
    // A viewer leaving must not disconnect or display an error over the others.
    session.onRemoteHangup = () {
      if (connectedMonitorCount == 0) onRemoteHangup?.call();
    };
    _additionalMonitors.add(session);
    try {
      await session._startTransmitter(
        isHd: _isHd,
        sharedStream: _localStream,
        credentials: credentials,
      );
      if (credentials == null && session.pairingUri != null) {
        await _pairingRepository?.remember(session.pairingUri!);
      }
      if (!_canHostMonitors || generation != _sessionGeneration) {
        throw StateError('Kamera již není dostupná.');
      }
      session._nightMode = _nightMode;
      session._torchEnabled = _torchEnabled;
      await session._publishVideoSettings();
      return CameraMonitorPairing(session.roomCode!, session.pairingUri!);
    } catch (_) {
      _additionalMonitors.remove(session);
      await session.stop();
      rethrow;
    }
  }

  bool get isAutoReconnecting =>
      state != AudioConnectionState.connected &&
      _autoReconnectEnabled &&
      (_reconnectTimer?.isActive == true ||
          _reconnecting ||
          _reconnectTimeoutTimer?.isActive == true ||
          _additionalMonitors.any((session) => session.isAutoReconnecting));

  void setAutoReconnectEnabled(bool enabled) {
    if (_autoReconnectEnabled == enabled) return;
    _autoReconnectEnabled = enabled;
    for (final session in _additionalMonitors) {
      session.setAutoReconnectEnabled(enabled);
    }
    _cancelReconnectTimers();
    if (enabled &&
        (_state == AudioConnectionState.disconnected ||
            _state == AudioConnectionState.error ||
            (_reconnectAttempts > 0 &&
                !_reconnecting &&
                _state != AudioConnectionState.connected))) {
      _reconnectAttempts = 0;
      _scheduleReconnect();
    }
    onStateChanged?.call(state);
  }

  void _cancelReconnectTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = null;
  }

  /// Reuses the current pairing; false means a new pairing is needed.
  Future<bool> reconnect() async {
    if (!_sessionActive || _role == null || _stopping) return false;
    if (_reconnecting) return true;
    for (final session in _additionalMonitors) {
      if (session._state != AudioConnectionState.connected) {
        unawaited(session.reconnect());
      }
    }
    if (_state == AudioConnectionState.connected) return true;
    _cancelReconnectTimers();
    _reconnectAttempts = 0;
    await _reconnect(automatic: false);
    return true;
  }

  String? get roomCode => _signaling.roomCode;
  String? get pairingUri => _signaling.pairingUri;
  bool get isTalkbackEnabled => _talkbackEnabled;
  RTCVideoRenderer? get localVideoRenderer => _localVideoRenderer;
  RTCVideoRenderer? get remoteVideoRenderer => _remoteVideoRenderer;
  MonitorTelemetry get telemetry => _telemetry;
  bool get isRecording => _mediaRecorder != null;
  bool get canRecord =>
      _role == AudioMonitorRole.receiver &&
      (_remoteVideoRenderer?.srcObject?.getVideoTracks().isNotEmpty ?? false);

  Future<String> startTransmitter({bool isHd = false}) =>
      _startTransmitter(isHd: isHd);

  Future<String> _startTransmitter({
    required bool isHd,
    MediaStream? sharedStream,
    AudioPairingCredentials? credentials,
  }) async {
    if (_mode == AudioConnectionMode.internet || isHd) _requirePremium();
    await _prepare(AudioMonitorRole.transmitter);
    final generation = _sessionGeneration;
    _hasConnectedOnce = false;
    _setState(AudioConnectionState.creatingRoom);
    try {
      _sessionActive = true;
      _reconnectAttempts = 0;
      _configureSignaling();
      final savedPairings = _ownsLocalStream
          ? await _pairingRepository?.load(
                  _mode == AudioConnectionMode.wifi
                      ? AudioPairingMode.wifi
                      : AudioPairingMode.internet,
                ) ??
                <AudioPairingCredentials>[]
          : <AudioPairingCredentials>[];
      if (_stopping || generation != _sessionGeneration) {
        throw StateError('Kamera již není dostupná.');
      }
      final restored = credentials ?? savedPairings.firstOrNull;
      _hasConnectedOnce = restored != null;
      final code = await _signaling.createRoom(
        credentials:
            restored ??
            (!_ownsLocalStream
                ? AudioPairingCredentials.generate(
                    mode: _mode == AudioConnectionMode.wifi
                        ? AudioPairingMode.wifi
                        : AudioPairingMode.internet,
                  )
                : null),
      );
      if (_ownsLocalStream &&
          restored == null &&
          _signaling.pairingUri != null) {
        await _pairingRepository?.remember(_signaling.pairingUri!);
      }
      if (_stopping || generation != _sessionGeneration) {
        throw StateError('Kamera již není dostupná.');
      }
      final connection = await _createConnection();
      if (_stopping || generation != _sessionGeneration) {
        await connection.close();
        throw StateError('Kamera již není dostupná.');
      }
      _peerConnection = connection;
      _isHd = isHd;
      _nightMode = false;
      _localStream =
          sharedStream ??
          await navigator.mediaDevices.getUserMedia({
            'audio': _audioConstraints(AudioMonitorRole.transmitter),
            'video': CameraVideoController.constraints(
              isHd: isHd,
              useFrontCamera: false,
            ),
          });
      for (final track in _localStream!.getTracks()) {
        final sender = await _peerConnection!.addTrack(track, _localStream!);
        if (track.kind == 'video') _videoSender = sender;
        if (track.kind == 'video' && _ownsLocalStream) {
          _cameraVideo = CameraVideoController(
            stream: _localStream!,
            sender: sender,
            senders: _cameraSenders,
            isHd: isHd,
            capture: navigator.mediaDevices.getUserMedia,
            onTrackChanged: () {
              _localVideoRenderer?.srcObject = null;
              _localVideoRenderer?.srcObject = _localStream;
              for (final track
                  in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
                track.enabled = !_appBackgrounded;
              }
            },
          );
        }
      }
      if (_ownsLocalStream) {
        _localVideoRenderer = RTCVideoRenderer();
        await _localVideoRenderer!.initialize();
        _localVideoRenderer!.srcObject = _localStream;
        await _startForegroundService('transmitter');
      }
      if (_appBackgrounded && _ownsLocalStream) await setAppBackgrounded(true);
      _setState(AudioConnectionState.waitingForPeer);
      await _sendInitialOfferIfReady();
      for (final pairing
          in _isPremium
              ? savedPairings.skip(1).take(DeviceLimits.monitors - 1)
              : <AudioPairingCredentials>[]) {
        if (_stopping || generation != _sessionGeneration) {
          throw StateError('Kamera již není dostupná.');
        }
        await _openMonitorPairing(credentials: pairing);
      }
      return code;
    } catch (error) {
      await _fail(error);
      rethrow;
    }
  }

  Future<bool> joinAsReceiver(String pairingValue) async {
    if (_mode == AudioConnectionMode.internet) _requirePremium();
    await _prepare(AudioMonitorRole.receiver);
    final generation = _sessionGeneration;
    bool isCurrent() =>
        !_stopping && generation == _sessionGeneration && _sessionActive;
    _setState(AudioConnectionState.connecting);
    try {
      _sessionActive = true;
      _lastPairingValue = pairingValue;
      _reconnectAttempts = 0;
      _configureSignaling();
      final joined = await _signaling
          .joinRoom(pairingValue)
          .timeout(const Duration(seconds: 45));
      if (!isCurrent()) return false;
      if (!joined) {
        await _fail(StateError('Relace nebyla nalezena.'));
        return false;
      }
      if (_peerConnection == null) {
        final connection = await _createConnection();
        if (!isCurrent()) {
          await connection.close();
          return false;
        }
        _peerConnection = connection;
      }
      await _startForegroundService('receiver');
      _watchNegotiation();
      return isCurrent();
    } catch (error) {
      if (!isCurrent()) return false;
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await Helper.setAppleAudioIOMode(
        role == AudioMonitorRole.transmitter
            ? AppleAudioIOMode.localAndRemote
            : AppleAudioIOMode.remoteOnly,
        preferSpeakerOutput: true,
      );
      await Helper.ensureAudioSession();
    }
  }

  void _configureSignaling() {
    final generation = _sessionGeneration;
    bool isCurrent() =>
        _sessionActive && !_stopping && generation == _sessionGeneration;
    _signaling.onPeerReady = () {
      if (!isCurrent()) return;
      _peerReady = true;
      unawaited(_sendInitialOfferIfReady());
    };
    _signaling.onOffer = (offer) {
      if (isCurrent()) unawaited(_handleOffer(offer));
    };
    _signaling.onAnswer = (answer) {
      if (isCurrent()) unawaited(_handleAnswer(answer));
    };
    _signaling.onCandidate = (candidate) {
      if (isCurrent()) unawaited(_handleCandidate(candidate));
    };
    _signaling.onControl = (message) {
      if (isCurrent()) _handleControl(message);
    };
    _signaling.onRemoteHangup = () {
      if (!isCurrent()) return;
      _setState(AudioConnectionState.disconnected);
      if (connectedMonitorCount == 0) onRemoteHangup?.call();
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
    final sessionGeneration = _sessionGeneration;
    bool isCurrent() =>
        _sessionActive && !_stopping && sessionGeneration == _sessionGeneration;
    final connection = await createPeerConnection({
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
    });
    if (generation != _connectionGeneration) {
      await connection.close();
      throw StateError('Connection creation was cancelled.');
    }
    connection.onIceCandidate = (candidate) {
      if (generation != _connectionGeneration ||
          !isCurrent() ||
          candidate.candidate == null) {
        return;
      }
      _signaling.addCandidate({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    connection.onTrack = (event) {
      if (generation == _connectionGeneration && isCurrent()) {
        unawaited(_handleRemoteTrack(event));
      }
    };
    connection.onConnectionState = (connectionState) {
      if (generation != _connectionGeneration || !isCurrent()) return;
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
    _applyReceiverMute();
    if (!kIsWeb) await Helper.setSpeakerphoneOn(true);
  }

  void setTransmitterMuted(bool muted) {
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  void setReceiverMuted(bool muted) {
    _receiverMuted = muted;
    _applyReceiverMute();
  }

  void _applyReceiverMute() {
    for (final track
        in _remoteAudioRenderer?.srcObject?.getAudioTracks() ??
            <MediaStreamTrack>[]) {
      track.enabled = _receiverViewing && !_receiverMuted;
    }
  }

  Future<void> setReceiverViewing(bool viewing) async {
    _receiverViewing = viewing;
    _applyReceiverMute();
    if (_role == AudioMonitorRole.receiver &&
        _state == AudioConnectionState.connected) {
      await _sendControl({
        'kind': 'viewer_activity',
        'active': viewing || _recordingNeedsVideo,
        'videoEnabled': !_appBackgrounded || _recordingNeedsVideo,
        'hdAllowed': _isPremium,
      });
    }
  }

  /// Keep audio alive in the background; video also stays active while recording.
  Future<void> setAppBackgrounded(bool backgrounded) async {
    _appBackgrounded = backgrounded;
    if (_role == AudioMonitorRole.receiver) {
      await setReceiverViewing(_receiverViewing);
      return;
    }
    if (!_ownsLocalStream) return;
    await _cameraVideo?.settled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !backgrounded;
    }
    for (final session in [this, ..._additionalMonitors]) {
      await session._applyViewerActivity();
      await session._publishVideoSettings();
    }
  }

  Future<void> _applyViewerActivity() {
    _viewerUpdate = _viewerUpdate.then((_) async {
      final connection = _peerConnection;
      if (connection == null || _role != AudioMonitorRole.transmitter) return;
      try {
        final senders = await connection.getSenders();
        if (!identical(connection, _peerConnection)) return;
        for (final sender in senders) {
          final parameters = sender.parameters;
          final encodings = parameters.encodings;
          if (encodings == null || encodings.isEmpty) continue;
          for (final encoding in encodings) {
            encoding.active =
                _viewerActive &&
                (sender.track?.kind != 'video' ||
                    (_viewerVideoEnabled && !_cameraBackgrounded));
            if (sender.track?.kind == 'video') {
              encoding.scaleResolutionDownBy = _isHd && !_viewerHdAllowed
                  ? 1.5
                  : 1.0;
            }
          }
          await sender.setParameters(parameters);
        }
      } catch (error) {
        debugPrint('ViewVee viewer activity: $error');
      }
    });
    return _viewerUpdate;
  }

  Future<void> switchCamera() async {
    if (_role == AudioMonitorRole.receiver) {
      if (!await _requestCameraSetting('switchCamera', true)) {
        throw StateError('Přepnutí kamery se nezdařilo.');
      }
      return;
    }
    await _cameraVideo?.settled;
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) throw StateError('Kamera není dostupná.');
    if (_torchEnabled && !await setTorchEnabled(false)) {
      throw StateError('Svítilnu se nepodařilo vypnout.');
    }
    // Android returns the new camera facing, not a success flag.
    await Helper.switchCamera(tracks.first);
    final camera = _cameraVideo;
    if (camera != null) camera.useFrontCamera = !camera.useFrontCamera;
    await _publishVideoSettings();
  }

  Future<void> setVideoQuality({required bool isHd}) async {
    if (isHd) _requirePremium();
    if (_role == AudioMonitorRole.receiver) {
      if (!await _requestCameraSetting('isHd', isHd)) {
        throw StateError('Změna kvality se nezdařila.');
      }
      return;
    }
    final camera = _cameraVideo;
    if (camera == null) return;
    final invitation = _creatingMonitorPairing;
    if (invitation != null) {
      try {
        await invitation;
      } catch (_) {}
    }
    await camera.setQuality(isHd);
    _isHd = camera.isHd;
    if (_torchEnabled) await setTorchEnabled(true);
    await _publishVideoSettings();
  }

  Future<void> _publishVideoSettings() async {
    for (final session in _additionalMonitors.toList()) {
      session._isHd = _isHd;
      session._nightMode = _nightMode;
      session._torchEnabled = _torchEnabled;
      await session._publishVideoSettings();
    }
    onVideoSettingsChanged?.call();
    if (_state != AudioConnectionState.connected) return;
    if (!_viewerHdAllowed || !_viewerVideoEnabled || _cameraBackgrounded) {
      await _applyViewerActivity();
    }
    await _sendControl({
      'kind': 'video_settings',
      'isHd': _isHd && _viewerHdAllowed,
      'nightMode': _nightMode,
      'torchEnabled': _torchEnabled,
      'videoPaused': _cameraBackgrounded,
    });
  }

  Future<bool> setTorchEnabled(bool enabled) async {
    if (_role == AudioMonitorRole.receiver) {
      return _requestCameraSetting('torchEnabled', enabled);
    }
    await _cameraVideo?.settled;
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return false;
    try {
      final track = tracks.first;
      if (!await track.hasTorch()) return false;
      await track.setTorch(enabled);
      _torchEnabled = enabled;
      await _publishVideoSettings();
      return true;
    } on PlatformException catch (error) {
      debugPrint('ViewVee torch control: $error');
      return false;
    }
  }

  Future<bool> setNightModeEnabled(bool enabled) async {
    if (_role == AudioMonitorRole.receiver) {
      return _requestCameraSetting('nightMode', enabled);
    }
    await _cameraVideo?.settled;
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) return false;
    final track = tracks.first;
    try {
      await Helper.setExposureMode(track, CameraExposureMode.auto);
    } catch (error) {
      debugPrint('ViewVee exposure mode: $error');
    }
    // Native video constraints do not implement exposure compensation.
    // Apply the same low-light display filter at both ends of the session.
    _nightMode = enabled;
    await _publishVideoSettings();
    return true;
  }

  Future<bool> _requestCameraSetting(String setting, bool value) async {
    if (_state != AudioConnectionState.connected) return false;
    final id = ++_cameraRequestId;
    final result = Completer<bool>();
    _cameraRequests[id] = result;
    try {
      await _signaling.sendControl({
        'kind': 'camera_command',
        'id': id,
        'setting': setting,
        'value': value,
      });
      return await result.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
    } finally {
      _cameraRequests.remove(id);
    }
  }

  void _receiveCameraCommand(Map<String, dynamic> message) {
    if (_role != AudioMonitorRole.transmitter ||
        message['id'] is! int ||
        message['value'] is! bool ||
        !const [
          'isHd',
          'nightMode',
          'torchEnabled',
          'switchCamera',
        ].contains(message['setting'])) {
      return;
    }
    final owner = _cameraOwner ?? this;
    final generation = _sessionGeneration;
    owner._cameraCommands = (owner._cameraCommands ?? Future<void>.value())
        .then((_) async {
          if (generation != _sessionGeneration || !_sessionActive) return;
          var success = false;
          try {
            final value = message['value'] as bool;
            switch (message['setting']) {
              case 'isHd':
                await owner.setVideoQuality(isHd: value);
                success = owner.isHd == value;
              case 'nightMode':
                success = await owner.setNightModeEnabled(value);
              case 'switchCamera':
                await owner.switchCamera();
                success = true;
              case 'torchEnabled':
                success = await owner.setTorchEnabled(value);
            }
          } catch (error) {
            debugPrint('ViewVee remote camera command: $error');
          }
          if (generation != _sessionGeneration) return;
          await _sendControl({
            'kind': 'camera_command_result',
            'id': message['id'],
            'success': success,
          });
        });
  }

  Future<void> startRecording(String path) async {
    _requirePremium();
    if (_role != AudioMonitorRole.receiver) {
      throw StateError('Nahrávání je dostupné pouze na monitoru.');
    }
    if (_recordingNeedsVideo || _pendingRecordingStop != null) {
      throw StateError('Nahrávání už probíhá.');
    }
    final tracks =
        _remoteVideoRenderer?.srcObject?.getVideoTracks() ??
        <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      throw StateError('Video zatím není dostupné pro nahrávání.');
    }
    // Set before starting the native recorder: a lock during startup must not
    // send a video-pause request to the camera.
    _recordingStarting = true;
    final operation = _startNativeRecording(path, tracks.first);
    _pendingRecordingStart = operation;
    try {
      await operation;
    } finally {
      _pendingRecordingStart = null;
    }
  }

  Future<void> _startNativeRecording(
    String path,
    MediaStreamTrack track,
  ) async {
    final recorder = MediaRecorder(albumName: 'ViewVee');
    try {
      await setReceiverViewing(_receiverViewing);
      await recorder.start(
        path,
        videoTrack: track,
        audioChannel: RecorderAudioChannel.OUTPUT,
      );
      _mediaRecorder = recorder;
    } finally {
      _recordingStarting = false;
      // Also restores audio-only mode if startup fails while backgrounded.
      await setReceiverViewing(_receiverViewing);
    }
  }

  Future<void> stopRecording() async {
    try {
      await _pendingRecordingStart;
    } catch (_) {
      // The caller of startRecording receives the error; there is no recorder.
    }
    final pending = _pendingRecordingStop;
    if (pending != null) {
      await pending;
      return;
    }
    final recorder = _mediaRecorder;
    if (recorder == null) return;
    final operation = _finishNativeRecording(recorder);
    _pendingRecordingStop = operation;
    try {
      await operation;
    } finally {
      _pendingRecordingStop = null;
    }
  }

  Future<void> _finishNativeRecording(MediaRecorder recorder) async {
    try {
      await recorder.stop();
    } finally {
      _mediaRecorder = null;
      // Once explicitly stopped, a background monitor returns to audio only.
      await setReceiverViewing(_receiverViewing);
    }
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
    if (enabled) _requirePremium();
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
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          await Helper.setAppleAudioIOMode(AppleAudioIOMode.remoteOnly);
        }
        return;
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await Helper.setAppleAudioIOMode(
          AppleAudioIOMode.localAndRemote,
          preferSpeakerOutput: true,
        );
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
    _connectionGeneration++;
    _creatingConnection = null;
    for (final request in _cameraRequests.values) {
      if (!request.isCompleted) request.complete(false);
    }
    _cameraRequests.clear();
    _sessionGeneration++;
    _sessionActive = false;
    _cancelReconnectTimers();
    try {
      await _cameraVideo?.settled;
      final additional = _additionalMonitors.toList();
      _additionalMonitors.clear();
      for (final session in additional) {
        session.onStateChanged = null;
        session.onRemoteHangup = null;
        await session.stop();
      }
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
      for (final stream in [
        if (_ownsLocalStream) _localStream,
        _talkbackStream,
      ]) {
        for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
          track.stop();
        }
        await stream?.dispose();
      }
      _localStream = null;
      _cameraVideo = null;
      _videoSender = null;
      _isHd = false;
      _nightMode = false;
      _torchEnabled = false;
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
      if (_ownsLocalStream && manageForegroundService) {
        await _stopForegroundService();
      }
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
    if (!_autoReconnectEnabled ||
        !_sessionActive ||
        _stopping ||
        _reconnecting ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimer = Timer(_reconnectBackoff, () {
      _reconnectTimer = null;
      unawaited(_reconnect());
    });
    onStateChanged?.call(state);
  }

  Future<void> _reconnect({bool automatic = true}) async {
    if (_mode == AudioConnectionMode.internet && !_isPremium) {
      await stop();
      return;
    }
    if (!_sessionActive ||
        _stopping ||
        _reconnecting ||
        _role == null ||
        (automatic && !_autoReconnectEnabled)) {
      return;
    }
    final generation = _sessionGeneration;
    bool isCurrent() =>
        _sessionActive && !_stopping && generation == _sessionGeneration;
    _reconnecting = true;
    _reconnectAttempts += 1;
    _negotiationTimer?.cancel();
    _setState(AudioConnectionState.connecting);
    try {
      if (_role == AudioMonitorRole.transmitter && _localStream == null) {
        await startTransmitter(isHd: _isHd);
        return;
      }
      await (_cameraVideo ?? _cameraOwner?._cameraVideo)?.settled;
      if (!isCurrent()) return;
      _peerReady = false;
      _initialOfferSent = false;
      _remoteDescriptionSet = false;
      _pendingCandidates.clear();
      await _resetPeerConnection(keepLocalStream: true);
      if (!isCurrent() || _role == null) return;
      _configureSignaling();

      if (_role == AudioMonitorRole.transmitter) {
        final connection = await _createConnection();
        if (!isCurrent()) {
          await connection.close();
          return;
        }
        _peerConnection = connection;
        final stream = _localStream;
        if (stream == null) throw StateError('Kamera již není dostupná.');
        for (final track in stream.getTracks()) {
          final sender = await connection.addTrack(track, stream);
          if (!isCurrent()) return;
          if (track.kind == 'video') {
            _videoSender = sender;
            _cameraVideo?.sender = sender;
          }
        }
        await _signaling.rearmForNewPeer();
        if (!isCurrent()) return;
        if (_state != AudioConnectionState.connected && !_initialOfferSent) {
          _setState(AudioConnectionState.waitingForPeer);
        }
        await _sendInitialOfferIfReady();
      } else {
        final pairingValue = _lastPairingValue;
        if (pairingValue == null) throw StateError('Chybí párovací údaje.');
        await _signaling.hangUp();
        if (!isCurrent()) return;
        _configureSignaling();
        final joined = await _signaling
            .joinRoom(pairingValue)
            .timeout(const Duration(seconds: 45));
        if (!isCurrent()) return;
        if (!joined) throw StateError('Kamera nebyla nalezena.');
        if (_peerConnection == null) {
          final connection = await _createConnection();
          if (!isCurrent()) {
            await connection.close();
            return;
          }
          _peerConnection = connection;
        }
      }
      // Registration alone is not a recovered media connection. Retry if ICE
      // negotiation stalls, and reset the attempt count only when connected.
      if (isCurrent() &&
          _state != AudioConnectionState.connected &&
          _autoReconnectEnabled) {
        _reconnectTimeoutTimer?.cancel();
        _reconnectTimeoutTimer = Timer(const Duration(seconds: 40), () {
          if (!isCurrent() ||
              !_autoReconnectEnabled ||
              _state == AudioConnectionState.connected) {
            return;
          }
          _setState(AudioConnectionState.disconnected);
          _scheduleReconnect();
        });
      }
    } catch (error) {
      if (!isCurrent()) return;
      if (connectedMonitorCount == 0) onError?.call(error);
      _setState(AudioConnectionState.disconnected);
    } finally {
      if (generation == _sessionGeneration) {
        _reconnecting = false;
        if (isCurrent() && _state == AudioConnectionState.disconnected) {
          _scheduleReconnect();
        }
        onStateChanged?.call(state);
      }
    }
  }

  Future<void> _resetPeerConnection({required bool keepLocalStream}) async {
    _connectionGeneration++;
    _creatingConnection = null;
    final connection = _peerConnection;
    _peerConnection = null;
    _videoSender = null;
    connection?.onConnectionState = null;
    connection?.onIceCandidate = null;
    connection?.onTrack = null;
    try {
      await connection?.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!keepLocalStream) {
      for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      await _localStream?.dispose();
      _localStream = null;
    }
  }

  Future<void> _rememberConnectedMonitor() async {
    final uri = pairingUri;
    if (uri == null) return;
    try {
      await (_cameraOwner ?? this)._pairingRepository?.markPaired(uri);
    } catch (_) {
      // A storage failure must not interrupt the active media connection.
      debugPrint('ViewVee: could not save the paired monitor.');
    }
  }

  void _setState(AudioConnectionState value) {
    if (_state == value) return;
    _state = value;
    onConnectionStateObserved?.call(value);
    if (value == AudioConnectionState.connected) {
      _hasConnectedOnce = true;
      _cancelReconnectTimers();
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _negotiationTimer?.cancel();
      _startMonitoring();
      if (_role == AudioMonitorRole.transmitter) {
        unawaited(_rememberConnectedMonitor());
        unawaited(_publishVideoSettings());
        if (!_viewerActive || !_viewerVideoEnabled || _cameraBackgrounded) {
          unawaited(_applyViewerActivity());
        }
      }
      if (_role == AudioMonitorRole.receiver) {
        unawaited(setReceiverViewing(_receiverViewing));
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
    onStateChanged?.call(state);
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
        try {
          batteryLevel = await _battery.batteryLevel;
        } catch (_) {
          // Battery telemetry is optional; sound alerts must continue.
        }
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
      if (_motionDetectionEnabled && !_cameraBackgrounded) {
        await _detectMotion();
      }
    } catch (error) {
      debugPrint('ViewVee monitoring tick: $error');
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
      case 'camera_command':
        _receiveCameraCommand(message);
      case 'camera_command_result':
        if (_role != AudioMonitorRole.receiver) return;
        final request = _cameraRequests[message['id']];
        if (request != null && !request.isCompleted) {
          request.complete(message['success'] == true);
        }

      case 'viewer_activity':
        if (_role != AudioMonitorRole.transmitter ||
            message['active'] is! bool) {
          return;
        }
        _viewerActive = message['active'] as bool;
        _viewerVideoEnabled = message['videoEnabled'] != false;
        if (message['hdAllowed'] is bool) {
          _viewerHdAllowed = message['hdAllowed'] as bool;
        }
        unawaited(_applyViewerActivity());
        unawaited(_publishVideoSettings());
      case 'video_settings':
        if (_role != AudioMonitorRole.receiver) return;
        final isHd = message['isHd'];
        final nightMode = message['nightMode'];
        if (isHd is! bool || nightMode is! bool) return;
        _isHd = isHd && _isPremium;
        _nightMode = nightMode;
        _torchEnabled = message['torchEnabled'] == true;
        _remoteVideoPaused = message['videoPaused'] == true;
        onVideoSettingsChanged?.call();
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
      debugPrint('ViewVee control message: $error');
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
    if (!manageForegroundService && role != 'receiverTalkback') return;
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

class CameraMonitorPairing {
  const CameraMonitorPairing(this.roomCode, this.pairingUri);
  final String roomCode;
  final String pairingUri;
}
