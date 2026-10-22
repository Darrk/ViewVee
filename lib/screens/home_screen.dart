import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_repository.dart';
import '../audio/audio_monitor_service.dart';
import '../audio/audio_pairing.dart';
import '../audio/audio_pairing_repository.dart';
import '../config.dart';
import '../monitor/free_session_limit.dart';
import '../ads/session_break_ad.dart';
import '../monitor/monitor_settings.dart';
import '../monitor/camera_directory.dart';
import '../monitor/saved_camera_repository.dart';
import '../widgets/saved_camera_list.dart';
import '../notifications/monitor_notification_service.dart';
import '../recordings/recording_repository.dart';
import '../theme/viewvee_theme.dart';
import '../widgets/viewvee_app_drawer.dart';
import '../widgets/viewvee_logo.dart';
import 'account_menu_screen.dart';

enum DeviceRole { camera, monitor }

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.watchMode,
    required this.isGuest,
    required this.isPremium,
    required this.onWatchModeChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onPasswordReset,
    required this.onSignOut,
  });

  final WatchMode watchMode;
  final bool isGuest;
  final bool isPremium;
  final Future<void> Function(WatchMode mode) onWatchModeChanged;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode mode) onThemeModeChanged;
  final Future<void> Function(String email) onPasswordReset;
  final VoidCallback onSignOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _activeRoleKey = 'monitor.activeRole';
  static const _activeModeKey = 'monitor.activeMode';
  final _pairingRepository = AudioPairingRepository();
  late AudioMonitorService _audioMonitor;
  final _settingsRepository = MonitorSettingsRepository();
  final _cameraDirectory = CameraDirectory();
  final _notificationService = MonitorNotificationService();
  final _recordingRepository = RecordingRepository();
  late AudioConnectionMode _connectionMode;
  DeviceRole? _role;
  bool _frontCamera = false;
  late bool _isHd;
  late bool _isPremium;
  bool _flash = false;
  bool _nightMode = false;
  bool _videoSettingsBusy = false;
  bool _addingMonitor = false;
  bool _microphone = false;
  bool _monitorFullscreen = false;
  bool _appBackgrounded = false;
  Future<void> _lifecycleUpdate = Future<void>.value();
  bool _audioBusy = false;
  bool _backgroundBusy = false;
  AudioConnectionState _audioState = AudioConnectionState.idle;
  String? _pairingUri;
  String? _roomCode;
  String? _audioError;
  bool _motionNotification = true;
  bool _soundNotification = true;
  bool _connectionNotification = true;
  bool _autoReconnectEnabled = true;
  double _sensitivity = 1;
  MonitorTelemetry _telemetry = const MonitorTelemetry();
  late final FreeSessionLimit _freeSessionLimit;
  bool _freeBreakBusy = false;
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  RecordingSource? _recordingSource;
  String? _recordingPath;
  Duration _recordingElapsed = Duration.zero;
  bool _recordingBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appBackgrounded =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
    _freeSessionLimit = FreeSessionLimit(
      onExpired: () => unawaited(_endFreeSession()),
    );
    _isPremium = widget.isPremium;
    _cameraDirectory.setPremiumEnabled(_isPremium);
    _isHd = _isPremium;
    _connectionMode = _isPremium
        ? AudioConnectionMode.internet
        : AudioConnectionMode.wifi;
    _createAudioMonitor();
    _cameraDirectory.addListener(_onCameraDirectoryChanged);
    unawaited(_loadSettings());
    unawaited(_notificationService.initialize());
    unawaited(_restoreSession());
  }

  Future<void> _restoreSession() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final role = preferences.getString(_activeRoleKey);
      final mode = preferences.getString(_activeModeKey);
      if (!mounted || _role != null || role == null) return;
      if (mode == AudioConnectionMode.internet.name && !_isPremium) return;
      setState(() {
        _connectionMode = mode == AudioConnectionMode.internet.name
            ? AudioConnectionMode.internet
            : AudioConnectionMode.wifi;
        _createAudioMonitor();
      });
      if (role == DeviceRole.camera.name) {
        await _selectRole(DeviceRole.camera);
      } else if (role == DeviceRole.monitor.name) {
        final pairing = await _pairingRepository.monitorPairing(
          _connectionMode == AudioConnectionMode.wifi
              ? AudioPairingMode.wifi
              : AudioPairingMode.internet,
        );
        if (!mounted || _role != null) return;
        await _selectRole(DeviceRole.monitor);
        if (pairing != null && mounted) await _joinReceiver(pairing);
      }
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      return;
    }
    _appBackgrounded = state != AppLifecycleState.resumed;
    _lifecycleUpdate = _lifecycleUpdate
        .then((_) async {
          if (!mounted) return;
          await _cameraDirectory.setAppBackgrounded(_appBackgrounded);
          if (_role == DeviceRole.camera) {
            await _audioMonitor.setAppBackgrounded(_appBackgrounded);
          }
        })
        .catchError((Object error) {
          if (mounted) setState(() => _audioError = error.toString());
        });
  }

  void _createAudioMonitor() {
    _attachAudioMonitor(
      AudioMonitorService(mode: _connectionMode, isPremium: _isPremium),
    );
  }

  void _attachAudioMonitor(AudioMonitorService monitor) {
    _audioMonitor = monitor;
    unawaited(_audioMonitor.setAppBackgrounded(_appBackgrounded));
    _audioMonitor.setAutoReconnectEnabled(_autoReconnectEnabled);
    _audioMonitor.onStateChanged = (state) {
      if (!mounted || !identical(_audioMonitor, monitor)) return;
      setState(() {
        _audioState = state;
        if (state == AudioConnectionState.connected ||
            state == AudioConnectionState.waitingForPeer) {
          _audioError = null;
        }
        if (_role == DeviceRole.camera &&
            state == AudioConnectionState.waitingForPeer) {
          _pairingUri = _audioMonitor.pairingUri;
          _roomCode = _audioMonitor.roomCode;
        }
      });
      _updateFreeSessionLimit();
    };
    _audioMonitor.onRemoteHangup = () {
      if (!mounted || !identical(_audioMonitor, monitor)) return;
      setState(() => _audioError = 'Druhé zařízení se odpojilo.');
      if (_connectionNotification) {
        unawaited(
          _notificationService.show(MonitorNotificationType.connectionLost),
        );
      }
    };
    _audioMonitor.onError = (error) {
      if (!mounted || !identical(_audioMonitor, monitor)) return;
      setState(() => _audioError = error.toString());
    };
    _audioMonitor.onVideoSettingsChanged = () {
      if (!mounted || !identical(_audioMonitor, monitor)) return;
      setState(() {
        _isHd = _audioMonitor.isHd;
        _nightMode = _audioMonitor.nightMode;
        _flash = _audioMonitor.torchEnabled;
        _frontCamera = _audioMonitor.isFrontCamera;
      });
    };
    _audioMonitor.onTelemetry = (telemetry) {
      if (mounted && identical(_audioMonitor, monitor)) {
        setState(() => _telemetry = telemetry);
      }
    };
    _audioMonitor.onDetection = (event) {
      if (!mounted || !identical(_audioMonitor, monitor)) return;
      final type = switch (event) {
        MonitorDetectionEvent.motion when _motionNotification =>
          MonitorNotificationType.motion,
        MonitorDetectionEvent.sound when _soundNotification =>
          MonitorNotificationType.sound,
        _ => null,
      };
      if (type != null) {
        unawaited(
          _notificationService.show(
            type,
            watchMode: widget.watchMode,
            inForeground: !_appBackgrounded,
          ),
        );
      }
    };
    unawaited(_syncDetectionSettings());
    _updateFreeSessionLimit();
  }

  final Set<String> _camerasAwaitingName = {};
  bool _showingCameraName = false;

  void _offerNewCameraName() {
    if (!mounted ||
        _role != DeviceRole.monitor ||
        _audioBusy ||
        _showingCameraName) {
      return;
    }
    final camera = _cameraDirectory.cameras
        .where(
          (camera) =>
              _camerasAwaitingName.contains(camera.id) &&
              _cameraDirectory.stateOf(camera.id) ==
                  AudioConnectionState.connected,
        )
        .firstOrNull;
    if (camera == null) return;
    _showingCameraName = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted ||
            _role != DeviceRole.monitor ||
            !_cameraDirectory.cameras.any((entry) => entry.id == camera.id) ||
            _cameraDirectory.stateOf(camera.id) !=
                AudioConnectionState.connected) {
          return;
        }
        _camerasAwaitingName.remove(camera.id);
        if (camera.name == null) {
          await _renameSavedCamera(camera, firstPairing: true);
        }
      } finally {
        _showingCameraName = false;
      }
    });
  }

  void _onCameraDirectoryChanged() {
    if (!mounted || _role != DeviceRole.monitor) return;
    final selected = _cameraDirectory.selectedService;
    setState(() {
      if (selected == null) {
        _audioState = AudioConnectionState.idle;
        return;
      }
      if (!identical(_audioMonitor, selected)) {
        _attachAudioMonitor(selected);
        _audioError = null;
      }
      _audioState = selected.state;
      _isHd = selected.isHd;
      _nightMode = selected.nightMode;
      _flash = selected.torchEnabled;
      _microphone = selected.isTalkbackEnabled;
      _telemetry = selected.telemetry;
    });
    _offerNewCameraName();
    _updateFreeSessionLimit();
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsRepository.load();
    if (!mounted) return;
    setState(() {
      _motionNotification = settings.motionEnabled;
      _soundNotification = settings.soundEnabled;
      _connectionNotification = settings.connectionEnabled;
      _autoReconnectEnabled = settings.autoReconnectEnabled;
      _sensitivity = settings.sensitivity.toDouble();
    });
    _audioMonitor.setAutoReconnectEnabled(_autoReconnectEnabled);
    _cameraDirectory.setAutoReconnectEnabled(_autoReconnectEnabled);
    await _syncDetectionSettings();
  }

  Future<void> _saveSettings() async {
    await _settingsRepository.save(
      MonitorSettings(
        motionEnabled: _motionNotification,
        soundEnabled: _soundNotification,
        connectionEnabled: _connectionNotification,
        autoReconnectEnabled: _autoReconnectEnabled,
        sensitivity: _sensitivity.round(),
      ),
    );
    await _syncDetectionSettings();
  }

  Future<void> _syncDetectionSettings() => _audioMonitor.configureDetection(
    motionEnabled: _motionNotification,
    soundEnabled: _soundNotification,
    sensitivity: _sensitivity.round(),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_monitorFullscreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _cameraDirectory.removeListener(_onCameraDirectoryChanged);
    _cameraDirectory.dispose();
    _recordingTimer?.cancel();
    _freeSessionLimit.dispose();
    final recordingPath = _recordingPath;
    final recordingStartedAt = _recordingStartedAt;
    final recordingSource = _recordingSource;
    if (recordingPath != null &&
        recordingStartedAt != null &&
        recordingSource != null) {
      unawaited(
        _recordingRepository.saveMetadata(
          path: recordingPath,
          source: recordingSource,
          createdAt: recordingStartedAt,
          duration: DateTime.now().difference(recordingStartedAt),
        ),
      );
    }
    _audioMonitor.onStateChanged = null;
    _audioMonitor.onRemoteHangup = null;
    _audioMonitor.onError = null;
    _audioMonitor.onTelemetry = null;
    _audioMonitor.onVideoSettingsChanged = null;
    _audioMonitor.onDetection = null;
    unawaited(_audioMonitor.stop());
    super.dispose();
  }

  void _setMonitorFullscreen(bool fullscreen) {
    setState(() => _monitorFullscreen = fullscreen);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_monitorFullscreen && _role == DeviceRole.monitor) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _setMonitorFullscreen(false);
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(child: SizedBox.expand(child: _monitorVideoSurface())),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            key: const Key('homeMenuButton'),
            tooltip: context.vv('Otevřít menu'),
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu_rounded),
          ),
        ),
        title: _role == null
            ? null
            : const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ViewVeeMark(size: 34),
                  SizedBox(width: 8),
                  VvText(
                    'ViewVee',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
        actions: [
          if (_role != null) ...[
            IconButton(
              key: const Key('deviceRoleBackButton'),
              tooltip: context.vv('Zpět na výběr role'),
              onPressed: _leaveDeviceRole,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            IconButton(
              tooltip: context.vv('Nastavení'),
              onPressed: _showSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ],
      ),
      drawer: _buildAppDrawer(),
      body: SafeArea(
        child: _role == null
            ? _RoleSelection(
                connectionMode: _connectionMode,
                isPremium: _isPremium,
                onConnectionModeChanged: _changeConnectionMode,
                onSelected: _selectRole,
              )
            : _role == DeviceRole.camera
            ? _cameraView()
            : _monitorView(),
      ),
    );
  }

  Widget _buildAppDrawer() => ViewVeeAppDrawer(
    watchMode: widget.watchMode,
    activeDestination: ViewVeeDrawerDestination.monitor,
    isPremium: _isPremium,
    onOpenMonitor: _openWatchModeFromDrawer,
    onOpenDevices: () => _openAccountMenu(ViewVeeDrawerDestination.devices),
    onOpenRecordings: () => _openAccountMenu(
      _isPremium
          ? ViewVeeDrawerDestination.recordings
          : ViewVeeDrawerDestination.subscription,
    ),
    onOpenAccount: () => _openAccountMenu(ViewVeeDrawerDestination.account),
    onOpenSubscription: () =>
        _openAccountMenu(ViewVeeDrawerDestination.subscription),
    onOpenPreferences: () =>
        _openAccountMenu(ViewVeeDrawerDestination.preferences),
    onOpenSupport: () => _openAccountMenu(ViewVeeDrawerDestination.support),
    onOpenAbout: () => _openAccountMenu(ViewVeeDrawerDestination.about),
    onSignOut: widget.onSignOut,
  );

  void _openWatchModeFromDrawer() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final selected = await showViewVeeWatchModePicker(
        context,
        widget.watchMode,
      );
      if (selected != null && selected != widget.watchMode) {
        await widget.onWatchModeChanged(selected);
      }
    });
  }

  Future<void> _openAccountMenu(ViewVeeDrawerDestination destination) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountMenuScreen(
          isGuest: widget.isGuest,
          isPremium: _isPremium,
          watchMode: widget.watchMode,
          themeMode: widget.themeMode,
          initialDestination: destination,
          onWatchModeChanged: widget.onWatchModeChanged,
          onThemeModeChanged: widget.onThemeModeChanged,
          onPasswordReset: widget.onPasswordReset,
          onAddDevice: _addDevice,
          onSignOut: widget.onSignOut,
        ),
      ),
    );
    if (!mounted) return;
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final premium =
        !Config.enablePremiumFeatures ||
        (preferences.getBool(AuthRepository.premiumUnlockedKey) ?? false);
    final premiumWasRemoved = _isPremium && !premium;
    final mustLeaveInternet =
        !premium && _connectionMode == AudioConnectionMode.internet;
    if (premiumWasRemoved) {
      await _audioMonitor.setTalkbackEnabled(false);
      await _stopRecording(showMessage: false);
      await _audioMonitor.setVideoQuality(isHd: false);
    }
    if (mustLeaveInternet) {
      _audioMonitor.onStateChanged = null;
      _audioMonitor.onRemoteHangup = null;
      _audioMonitor.onError = null;
      await _cameraDirectory.stop();
      await _audioMonitor.stop();
    }
    if (!mounted) return;
    _audioMonitor.setPremiumEnabled(premium);
    _cameraDirectory.setPremiumEnabled(premium);
    setState(() {
      _isPremium = premium;
      if (!_isPremium) {
        _isHd = false;
        _connectionMode = AudioConnectionMode.wifi;
      }
      if (mustLeaveInternet) {
        _role = null;
        _audioState = AudioConnectionState.idle;
        _pairingUri = null;
        _roomCode = null;
        _audioError = null;
        _createAudioMonitor();
      }
    });
    _updateFreeSessionLimit();
  }

  void _updateFreeSessionLimit() {
    if (_isPremium) {
      _freeSessionLimit.reset();
      return;
    }
    _freeSessionLimit.update(
      running:
          !_isPremium &&
          _role != null &&
          _audioState == AudioConnectionState.connected,
    );
  }

  Future<void> _endFreeSession() async {
    if (!mounted || _isPremium) return;
    final previousRole = _role;
    await _leaveDeviceRole();
    if (!mounted || _appBackgrounded) return;
    if (await _continueAfterFreeLimit() && mounted && previousRole != null) {
      await _selectRole(previousRole);
    }
  }

  Future<bool> _continueAfterFreeLimit() async {
    if (_isPremium || !_freeSessionLimit.expired) return true;
    if (_freeBreakBusy) return false;
    _freeBreakBusy = true;
    try {
      final continueFree = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const VvText('Hodina sledování skončila'),
          content: const VvText(
            'Ve Free můžete po reklamní přestávce pokračovat další hodinu. Premium nabízí sledování bez přerušení a reklam.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VvText('Ukončit'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VvText('Zobrazit Premium'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VvText('Pokračovat'),
            ),
          ],
        ),
      );
      if (!mounted || continueFree == null) return false;
      if (!continueFree) {
        await _openAccountMenu(ViewVeeDrawerDestination.subscription);
        return _isPremium;
      }
      await SessionBreakAd().show();
      if (!mounted) return false;
      _freeSessionLimit.reset();
      return true;
    } finally {
      _freeBreakBusy = false;
    }
  }

  Future<void> _showPremiumRequired({
    required String title,
    required String description,
    required IconData icon,
    required String buttonKey,
  }) async {
    final openPremium = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      ViewVeeColors.teal,
                      ViewVeeColors.blue,
                      ViewVeeColors.violet,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: Colors.white, size: 30),
              ),
              const SizedBox(height: 16),
              VvText(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              VvText(
                description,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: Key(buttonKey),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.workspace_premium_rounded),
                label: const VvText('Zobrazit Premium'),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const VvText('Teď ne'),
              ),
            ],
          ),
        ),
      ),
    );
    if (openPremium == true && mounted) {
      await _openAccountMenu(ViewVeeDrawerDestination.subscription);
    }
  }

  Future<void> _showHdPremiumRequired() => _showPremiumRequired(
    title: 'HD kvalita je součástí Premium',
    description:
        'Bezplatný tarif používá SD 480p. S Premium odemknete '
        'ostřejší HD 720p video.',
    icon: Icons.hd_rounded,
    buttonKey: 'openPremiumFromHd',
  );

  Future<void> _showRecordingPremiumRequired() => _showPremiumRequired(
    title: 'Nahrávání je součástí Premium',
    description:
        'S Premium můžete ukládat video z kamery i monitoru, '
        'záznamy přehrávat a bezpečně sdílet.',
    icon: Icons.video_library_rounded,
    buttonKey: 'openPremiumFromRecording',
  );

  Future<void> _addDevice(DevicePairingAction action) async {
    Navigator.of(context).pop();
    await _stopRecording(showMessage: false);
    await _cameraDirectory.stop();
    await _audioMonitor.stop();
    if (!mounted) return;
    setState(() {
      _role = null;
      _audioState = AudioConnectionState.idle;
      _pairingUri = null;
      _roomCode = null;
      _audioError = null;
    });
    await _selectRole(
      action == DevicePairingAction.camera
          ? DeviceRole.camera
          : DeviceRole.monitor,
    );
    if (action == DevicePairingAction.monitor && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPairingOptions();
      });
    }
  }

  Widget _cameraView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _AudioStatusBar(state: _audioState, onReconnect: _reconnectSession),
        if (_audioError != null) _AudioError(message: _audioError!),
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('backgroundCameraButton'),
            onPressed:
                !_audioBusy &&
                    !_backgroundBusy &&
                    (_audioState == AudioConnectionState.waitingForPeer ||
                        _audioState == AudioConnectionState.connected)
                ? _backgroundCamera
                : null,
            icon: const Icon(Icons.picture_in_picture_alt_rounded),
            label: const VvText('Spustit na pozadí'),
          ),
        ],
        if (_pairingUri != null &&
            _audioState != AudioConnectionState.connected) ...[
          const SizedBox(height: 12),
          _PairingPanel(
            pairingUri: _pairingUri!,
            roomCode: _roomCode ?? '------',
          ),
        ],
        const SizedBox(height: 12),
        _VideoSurface(
          title: _frontCamera ? 'Přední kamera' : 'Zadní kamera',
          connected: _audioState == AudioConnectionState.connected,
          reconnecting: _audioMonitor.isAutoReconnecting,
          overlay: _isHd ? 'HD 720p' : 'SD 480p',
          renderer: _audioMonitor.localVideoRenderer,
          mirror: _frontCamera,
          nightMode: _nightMode,
        ),
        const SizedBox(height: 12),
        Text(
          context
              .vv('Připojené monitory: {count}')
              .replaceAll('{count}', '${_audioMonitor.connectedMonitorCount}'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed:
              _addingMonitor ||
                  _videoSettingsBusy ||
                  _audioBusy ||
                  !_audioMonitor.canAddMonitor
              ? null
              : _showAdditionalMonitorPairing,
          icon: Icon(
            _isPremium
                ? Icons.add_to_queue_rounded
                : Icons.lock_outline_rounded,
          ),
          label: const VvText('Připojit další monitor'),
        ),
        const SizedBox(height: 20),
        _changeRoleButton(),
      ],
    );
  }

  Future<void> _changeRemoteCamera(
    Future<void> Function(AudioMonitorService) action,
  ) async {
    final camera = _audioMonitor;
    setState(() => _videoSettingsBusy = true);
    try {
      await action(camera);
    } catch (error) {
      if (mounted && identical(camera, _audioMonitor)) {
        setState(() => _audioError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _videoSettingsBusy = false);
    }
  }

  Widget _remoteCameraControls() {
    final enabled =
        _audioState == AudioConnectionState.connected &&
        !_audioBusy &&
        !_videoSettingsBusy;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ToggleControl(
                icon: Icons.flashlight_on_rounded,
                label: 'Svítilna',
                accentColor: ViewVeeColors.teal,
                value: _flash,
                onChanged: enabled
                    ? (value) => _changeRemoteCamera((camera) async {
                        final supported = await camera.setTorchEnabled(value);
                        if (!supported &&
                            mounted &&
                            identical(camera, _audioMonitor)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: VvText(
                                'Svítilna není na této kameře dostupná.',
                              ),
                            ),
                          );
                        }
                      })
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ToggleControl(
                icon: Icons.dark_mode_rounded,
                label: 'Noční režim',
                accentColor: ViewVeeColors.blue,
                value: _nightMode,
                onChanged: enabled
                    ? (value) => _changeRemoteCamera((camera) async {
                        if (!await camera.setNightModeEnabled(value)) {
                          throw StateError(
                            'Změna nočního režimu se nezdařila.',
                          );
                        }
                      })
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _videoQualityControl() {
    final canChangeQuality =
        _audioState == AudioConnectionState.connected &&
        !_audioBusy &&
        !_videoSettingsBusy &&
        !_audioMonitor.isRemoteVideoPaused;
    return PopupMenuButton<bool>(
      key: const Key('monitorVideoQuality'),
      tooltip: 'SD / HD',
      initialValue: _isHd,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 112, maxWidth: 144),
      onSelected: (isHd) async {
        if (isHd == _isHd) return;
        if (isHd && !_isPremium) {
          await _showHdPremiumRequired();
          return;
        }
        if (!canChangeQuality) return;
        await _changeRemoteCamera(
          (camera) => camera.setVideoQuality(isHd: isHd),
        );
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<bool>(
          value: false,
          enabled: canChangeQuality || !_isHd,
          checked: !_isHd,
          child: const VvText('SD'),
        ),
        CheckedPopupMenuItem<bool>(
          value: true,
          enabled: !_isPremium || canChangeQuality || _isHd,
          checked: _isHd,
          child: Row(
            children: [
              const VvText('HD'),
              if (!_isPremium) ...[
                const SizedBox(width: 8),
                const Icon(Icons.lock_outline_rounded, size: 16),
              ],
            ],
          ),
        ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            VvText(
              _isHd ? 'HD' : 'SD',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            if (_videoSettingsBusy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            else
              const Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: Colors.white,
              ),
          ],
        ),
      ),
    );
  }

  Widget _monitorVideoSurface() => _VideoSurface(
    title: _cameraDirectory.selectedCamera?.name ?? _modeLabel,
    connected: _audioState == AudioConnectionState.connected,
    reconnecting: _audioMonitor.isAutoReconnecting,
    overlay: _audioMonitor.isRemoteVideoPaused
        ? 'Pouze zvuk'
        : '${_isHd ? 'HD 720p' : 'SD 480p'} • Šifrováno',
    nightMode: _nightMode,
    renderer: _audioMonitor.isRemoteVideoPaused
        ? null
        : _audioMonitor.remoteVideoRenderer,
    recording: _recordingStartedAt != null,
    fullscreen: _monitorFullscreen,
    onToggleFullscreen: () => _setMonitorFullscreen(!_monitorFullscreen),
    qualityControl: _videoQualityControl(),
    recordingControl: _RecordingControl(
      recording: _recordingStartedAt != null,
      busy: _recordingBusy,
      elapsed: _recordingElapsed,
      locked: !_isPremium,
      enabled:
          _audioState == AudioConnectionState.connected &&
          _audioMonitor.canRecord,
      onLockedPressed: _showRecordingPremiumRequired,
      onPressed: _recordingStartedAt == null ? _startRecording : _stopRecording,
    ),
  );

  Widget _monitorView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SavedCameraList(
          cameras: _cameraDirectory.cameras,
          selectedId: _cameraDirectory.selectedId,
          stateOf: _cameraDirectory.stateOf,
          isLocked: _cameraDirectory.isCameraLocked,
          addLocked: !_isPremium && !_cameraDirectory.canAddCamera,
          lockedLabel: _isPremium ? 'Neaktivní' : 'Premium',
          busy: _audioBusy || _recordingBusy,
          onSelect: (id) => unawaited(_selectSavedCamera(id)),
          onAdd: _showPairingOptions,
          onRefresh: () => unawaited(_cameraDirectory.refresh()),
          onRename: (camera) => unawaited(_renameSavedCamera(camera)),
          onRemove: (id) => unawaited(_removeSavedCamera(id)),
        ),
        const SizedBox(height: 12),
        _AudioStatusBar(state: _audioState, onReconnect: _reconnectSession),
        if (_audioError != null) _AudioError(message: _audioError!),
        const SizedBox(height: 12),
        _monitorVideoSurface(),
        const SizedBox(height: 12),
        _remoteCameraControls(),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('monitorMute'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed:
                    _audioState == AudioConnectionState.connected && !_audioBusy
                    ? () {
                        setState(() {
                          _audioMonitor.setReceiverMuted(
                            !_audioMonitor.isReceiverMuted,
                          );
                        });
                      }
                    : null,
                icon: Icon(
                  _audioMonitor.isReceiverMuted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
                label: VvText(
                  _audioMonitor.isReceiverMuted ? 'Zapnout zvuk' : 'Ztlumit',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                key: const Key('monitorSwitchCamera'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed:
                    _audioState == AudioConnectionState.connected &&
                        !_audioBusy &&
                        !_videoSettingsBusy &&
                        !_audioMonitor.isRemoteVideoPaused
                    ? () =>
                          _changeRemoteCamera((camera) => camera.switchCamera())
                    : null,
                icon: const Icon(Icons.cameraswitch_rounded, size: 20),
                label: const VvText(
                  'Přepnout kameru',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Metric(
                icon: Icons.signal_wifi_4_bar_rounded,
                label: 'Signál',
                value: _signalLabel,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Metric(
                icon: Icons.battery_5_bar_rounded,
                label: 'Baterie kamery',
                value: _telemetry.batteryLevel == null
                    ? '--'
                    : '${_telemetry.batteryLevel} %',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_audioState == AudioConnectionState.idle ||
            _audioState == AudioConnectionState.error ||
            _audioState == AudioConnectionState.disconnected) ...[
          FilledButton.icon(
            key: const Key('pairCamera'),
            onPressed: _audioBusy ? null : _showPairingOptions,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const VvText('Spárovat kameru'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          key: const Key('monitorTalkback'),
          onPressed: !_isPremium
              ? _showTalkbackPremiumRequired
              : _audioState == AudioConnectionState.connected && !_audioBusy
              ? _toggleTalkback
              : null,
          icon: Icon(
            !_isPremium
                ? Icons.lock_outline_rounded
                : _microphone
                ? Icons.mic_rounded
                : Icons.mic_off_rounded,
          ),
          label: VvText(
            !_isPremium
                ? 'Obousměrný zvuk'
                : _microphone
                ? 'Ztlumit'
                : 'Zapnout zvuk',
          ),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 12),
        _changeRoleButton(),
      ],
    );
  }

  Widget _changeRoleButton() {
    return OutlinedButton.icon(
      onPressed: _leaveDeviceRole,
      icon: const Icon(Icons.swap_horiz_rounded),
      label: const VvText('Změnit roli zařízení'),
    );
  }

  Future<void> _leaveDeviceRole() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_activeRoleKey);
    await preferences.remove(_activeModeKey);
    if (_monitorFullscreen) _setMonitorFullscreen(false);
    await _stopRecording(showMessage: false);
    if (_flash && _role == DeviceRole.camera) {
      await _audioMonitor.setTorchEnabled(false);
    }
    await _cameraDirectory.stop();
    await _audioMonitor.stop();
    if (!mounted) return;
    setState(() {
      _role = null;
      _pairingUri = null;
      _roomCode = null;
      _audioError = null;
      _microphone = false;
      _flash = false;
      _nightMode = false;
      _createAudioMonitor();
    });
  }

  Future<void> _startRecording() async {
    if (_role != DeviceRole.monitor || _appBackgrounded) return;
    const source = RecordingSource.monitor;
    if (!_isPremium) {
      await _showRecordingPremiumRequired();
      return;
    }
    if (_recordingBusy || _recordingStartedAt != null) return;
    setState(() => _recordingBusy = true);
    final startedAt = DateTime.now();
    String? path;
    try {
      path = await _recordingRepository.createPath(source);
      await _audioMonitor.startRecording(path);
      await _recordingRepository.saveMetadata(
        path: path,
        source: source,
        createdAt: startedAt,
        duration: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _recordingStartedAt = startedAt;
        _recordingSource = source;
        _recordingPath = path;
        _recordingElapsed = Duration.zero;
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _recordingStartedAt == null) return;
        setState(() {
          _recordingElapsed = DateTime.now().difference(_recordingStartedAt!);
        });
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: VvText('Něco se pokazilo. Zkuste to prosím znovu.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Future<void> _stopRecording({bool showMessage = true}) async {
    final path = _recordingPath;
    final startedAt = _recordingStartedAt;
    final source = _recordingSource;
    if (_recordingBusy || path == null || startedAt == null || source == null) {
      return;
    }
    setState(() => _recordingBusy = true);
    _recordingTimer?.cancel();
    final duration = DateTime.now().difference(startedAt);
    try {
      await _audioMonitor.stopRecording();
      await _recordingRepository.saveMetadata(
        path: path,
        source: source,
        createdAt: startedAt,
        duration: duration,
      );
      if (!mounted) return;
      if (showMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: VvText('Nahrávka byla uložena.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: VvText('Něco se pokazilo. Zkuste to prosím znovu.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordingBusy = false;
          _recordingStartedAt = null;
          _recordingSource = null;
          _recordingPath = null;
          _recordingElapsed = Duration.zero;
        });
      }
    }
  }

  String get _modeLabel => switch (widget.watchMode) {
    WatchMode.baby => 'Dítě',
    WatchMode.pet => 'Mazlíček',
    WatchMode.home => 'Domov',
  };

  String get _signalLabel => switch (_telemetry.signalQuality) {
    MonitorSignalQuality.unknown => '--',
    MonitorSignalQuality.weak => 'Nízká',
    MonitorSignalQuality.good => 'Střední',
    MonitorSignalQuality.excellent => 'Vysoká',
  };

  Future<void> _changeConnectionMode(AudioConnectionMode mode) async {
    if (mode == _connectionMode) return;
    if (mode == AudioConnectionMode.internet && !_isPremium) {
      await _showPremiumRequired(
        title: 'Připojení přes internet je v Premium',
        description:
            'Bezplatný tarif funguje mezi telefony na stejné Wi‑Fi. '
            'Premium umožní sledování i přes mobilní data a mimo domov.',
        icon: Icons.public_rounded,
        buttonKey: 'openPremiumFromInternet',
      );
      return;
    }
    await _stopRecording(showMessage: false);
    _audioMonitor.onStateChanged = null;
    _audioMonitor.onRemoteHangup = null;
    _audioMonitor.onError = null;
    await _cameraDirectory.stop();
    await _audioMonitor.stop();
    setState(() {
      _connectionMode = mode;
      _audioState = AudioConnectionState.idle;
      _audioError = null;
      _pairingUri = null;
      _roomCode = null;
      _createAudioMonitor();
    });
    final role = _role;
    if (role != null) await _selectRole(role);
  }

  Future<void> _selectRole(DeviceRole role) async {
    if (!await _continueAfterFreeLimit() || !mounted) return;
    if (_connectionMode == AudioConnectionMode.internet && !_isPremium) {
      await _showPremiumRequired(
        title: 'Připojení přes internet je v Premium',
        description:
            'Bezplatný tarif funguje mezi telefony na stejné Wi‑Fi. '
            'Premium umožní sledování i přes mobilní data a mimo domov.',
        icon: Icons.public_rounded,
        buttonKey: 'openPremiumFromInternet',
      );
      return;
    }
    setState(() {
      _role = role;
      _audioError = null;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_activeRoleKey, role.name);
    await preferences.setString(_activeModeKey, _connectionMode.name);
    if (role == DeviceRole.camera) await _startTransmitter();
    if (role == DeviceRole.monitor) {
      await _audioMonitor.stop();
      try {
        await _cameraDirectory.start(_connectionMode);
      } catch (error) {
        if (mounted) setState(() => _audioError = error.toString());
      }
    }
    if (role == DeviceRole.monitor &&
        (_motionNotification ||
            _soundNotification ||
            _connectionNotification)) {
      await _notificationService.requestPermission();
    }
  }

  Future<void> _backgroundCamera() async {
    setState(() {
      _backgroundBusy = true;
      _audioError = null;
    });
    try {
      await Permission.notification.request();
      if (!mounted ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      await _audioMonitor.backgroundCamera();
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _showMultiDevicePremiumRequired() => _showPremiumRequired(
    title: 'Více zařízení',
    description: 'Více zařízení je součástí Premium.',
    icon: Icons.devices_rounded,
    buttonKey: 'openPremiumFromDevices',
  );

  Future<void> _showAdditionalMonitorPairing() async {
    if (!_isPremium) {
      await _showMultiDevicePremiumRequired();
      return;
    }
    if (_addingMonitor) return;
    setState(() => _addingMonitor = true);
    try {
      final pairing = await _audioMonitor.createMonitorPairing();
      if (!mounted || _role != DeviceRole.camera) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VvText(
                  'Připojit další monitor',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                _PairingPanel(
                  pairingUri: pairing.pairingUri,
                  roomCode: pairing.roomCode,
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _addingMonitor = false);
    }
  }

  Future<void> _reconnectSession() async {
    if (_audioBusy) return;
    setState(() => _audioError = null);
    if (await _audioMonitor.reconnect() || !mounted) return;
    if (_role == DeviceRole.camera) {
      await _startTransmitter();
    } else {
      await _showPairingOptions();
    }
  }

  Future<void> _startTransmitter() async {
    if (_audioBusy) return;
    setState(() {
      _audioBusy = true;
      _audioError = null;
    });
    try {
      var permission = await Permission.microphone.status;
      if (!permission.isGranted) {
        permission = await Permission.microphone.request();
      }
      if (!permission.isGranted) {
        throw StateError('Povolte přístup k mikrofonu v nastavení telefonu.');
      }
      var cameraPermission = await Permission.camera.status;
      if (!cameraPermission.isGranted) {
        cameraPermission = await Permission.camera.request();
      }
      if (!cameraPermission.isGranted) {
        throw StateError('Povolte přístup ke kameře v nastavení telefonu.');
      }
      final code = await _audioMonitor.startTransmitter(isHd: _isHd);
      if (!mounted) return;
      setState(() {
        _roomCode = code;
        _pairingUri = _audioMonitor.pairingUri;
      });
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _showCameraLimit() async {
    if (!_isPremium) {
      await _showMultiDevicePremiumRequired();
    } else {
      setState(() => _audioError = _cameraDirectory.cameraLimitMessage);
    }
  }

  Future<void> _showPairingOptions() async {
    if (!_cameraDirectory.canAddCamera) {
      await _showCameraLimit();
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const VvText(
                'Připojit kameru',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, 'scan'),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const VvText('Naskenovat QR kód'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'paste'),
                icon: const Icon(Icons.content_paste_rounded),
                label: const VvText('Vložit párovací odkaz'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'scan') {
      await _scanPairingCode();
    } else if (action == 'paste') {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) await _joinReceiver(data!.text!);
    }
  }

  Future<void> _scanPairingCode() async {
    if (_audioError != null) {
      setState(() => _audioError = null);
    }
    var permission = await Permission.camera.status;
    if (!permission.isGranted) permission = await Permission.camera.request();
    if (!mounted) return;
    if (!permission.isGranted) {
      setState(
        () => _audioError = 'Povolte přístup ke kameře pro skenování QR.',
      );
      return;
    }
    final pairingValue = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PairingScannerSheet(mode: _connectionMode),
    );
    if (pairingValue != null) await _joinReceiver(pairingValue);
  }

  Future<void> _joinReceiver(String pairingValue) async {
    if (_audioBusy) return;
    final expectedMode = _connectionMode == AudioConnectionMode.wifi
        ? AudioPairingMode.wifi
        : AudioPairingMode.internet;
    if (AudioPairingCredentials.tryParse(
          pairingValue,
          expectedMode: expectedMode,
        ) ==
        null) {
      setState(
        () => _audioError =
            'Tento QR kód není platný pro zvolený způsob připojení.',
      );
      return;
    }
    setState(() {
      _audioBusy = true;
      _audioError = null;
    });
    try {
      await _stopRecording(showMessage: false);
      final saved = SavedCamera.fromJson({'pairingUri': pairingValue})!;
      if (!_cameraDirectory.canAddCamera &&
          !_cameraDirectory.cameras.any((camera) => camera.id == saved.id)) {
        await _showCameraLimit();
        return;
      }
      final isNew = !_cameraDirectory.cameras.any(
        (camera) => camera.id == saved.id,
      );
      if (isNew) _camerasAwaitingName.add(saved.id);
      await _cameraDirectory.add(pairingValue);
      await _pairingRepository.rememberMonitor(pairingValue);
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) {
        setState(() => _audioBusy = false);
        _offerNewCameraName();
      }
    }
  }

  Future<void> _selectSavedCamera(String id) async {
    if (_cameraDirectory.isCameraLocked(id)) {
      await _showCameraLimit();
      return;
    }
    if (_audioBusy || _recordingBusy) return;
    setState(() => _audioBusy = true);
    try {
      if (_cameraDirectory.selectedId != id) {
        await _stopRecording(showMessage: false);
      }
      await _cameraDirectory.select(id);
      final camera = _cameraDirectory.selectedCamera;
      if (camera != null) {
        await _pairingRepository.rememberMonitor(camera.pairingUri);
      }
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _removeSavedCamera(String id) async {
    if (_audioBusy || _recordingBusy) return;
    setState(() => _audioBusy = true);
    try {
      if (_cameraDirectory.selectedId == id) {
        await _stopRecording(showMessage: false);
      }
      final camera = _cameraDirectory.cameras
          .where((camera) => camera.id == id)
          .firstOrNull;
      await _cameraDirectory.remove(id);
      if (camera != null) {
        await _pairingRepository.forgetMonitor(camera.pairingUri);
      }
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _renameSavedCamera(
    SavedCamera camera, {
    bool firstPairing = false,
  }) async {
    var draft = camera.name ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: VvText(firstPairing ? 'Název kamery' : 'Přejmenovat kameru'),
        content: TextFormField(
          initialValue: draft,
          onChanged: (value) => draft = value,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(labelText: context.vv('Název kamery')),
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const VvText('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft),
            child: const VvText('Uložit'),
          ),
        ],
      ),
    );
    if (name == null) return;
    try {
      await _cameraDirectory.rename(camera.id, name);
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    }
  }

  Future<void> _showTalkbackPremiumRequired() => _showPremiumRequired(
    title: 'Obousměrný zvuk',
    description:
        'Mluvení do kamery je součástí Premium. Zvuk z kamery můžete poslouchat zdarma.',
    icon: Icons.record_voice_over_rounded,
    buttonKey: 'openPremiumFromTalkback',
  );

  Future<void> _toggleTalkback() async {
    if (!_isPremium) {
      await _showTalkbackPremiumRequired();
      return;
    }
    setState(() => _audioBusy = true);
    try {
      final enable = !_microphone;
      if (enable) {
        var permission = await Permission.microphone.status;
        if (!permission.isGranted) {
          permission = await Permission.microphone.request();
        }
        if (!permission.isGranted) {
          throw StateError('Mikrofon není povolený.');
        }
      }
      await _audioMonitor.setTalkbackEnabled(enable);
      if (mounted) setState(() => _microphone = enable);
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void update(VoidCallback change) {
            setState(change);
            setModalState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.sync_rounded),
                    title: const VvText('Automaticky obnovit spojení'),
                    value: _autoReconnectEnabled,
                    onChanged: (value) {
                      update(() => _autoReconnectEnabled = value);
                      _audioMonitor.setAutoReconnectEnabled(value);
                      _cameraDirectory.setAutoReconnectEnabled(value);
                      unawaited(_saveSettings());
                    },
                  ),
                  const Divider(),
                  const SizedBox(height: 12),
                  const VvText(
                    'Chytré notifikace',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.directions_run_rounded),
                    title: const VvText('Detekce pohybu'),
                    value: _motionNotification,
                    onChanged: (value) {
                      update(() => _motionNotification = value);
                      if (value) {
                        unawaited(_notificationService.requestPermission());
                      }
                      unawaited(_saveSettings());
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.graphic_eq_rounded),
                    title: const VvText('Detekce zvuku'),
                    value: _soundNotification,
                    onChanged: (value) {
                      update(() => _soundNotification = value);
                      if (value) {
                        unawaited(_notificationService.requestPermission());
                      }
                      unawaited(_saveSettings());
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.link_off_rounded),
                    title: const VvText('Ztráta spojení'),
                    value: _connectionNotification,
                    onChanged: (value) {
                      update(() => _connectionNotification = value);
                      if (value) {
                        unawaited(_notificationService.requestPermission());
                      }
                      unawaited(_saveSettings());
                    },
                  ),
                  const SizedBox(height: 20),
                  const VvText(
                    'Citlivost',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  Slider(
                    value: _sensitivity,
                    min: 0,
                    max: 2,
                    divisions: 2,
                    label: const [
                      'Nízká',
                      'Střední',
                      'Vysoká',
                    ][_sensitivity.round()],
                    onChanged: (value) {
                      update(() => _sensitivity = value);
                      unawaited(_saveSettings());
                    },
                  ),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      VvText('Nízká'),
                      VvText('Střední'),
                      VvText('Vysoká'),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RoleSelection extends StatefulWidget {
  const _RoleSelection({
    required this.connectionMode,
    required this.isPremium,
    required this.onConnectionModeChanged,
    required this.onSelected,
  });
  final AudioConnectionMode connectionMode;
  final bool isPremium;
  final ValueChanged<AudioConnectionMode> onConnectionModeChanged;
  final ValueChanged<DeviceRole> onSelected;

  @override
  State<_RoleSelection> createState() => _RoleSelectionState();
}

class _RoleSelectionState extends State<_RoleSelection> {
  DeviceRole? _selectedRole;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 420,
                minHeight: constraints.maxHeight - 52,
              ),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
                tween: Tween(begin: 0, end: 1),
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 18 * (1 - value)),
                    child: child,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: ViewVeeLogo(width: 188, useDarkBackground: true),
                    ),
                    const SizedBox(height: 26),
                    VvText(
                      'Jak chcete tento telefon použít?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    VvText(
                      'Jeden telefon hlídá, druhý vám ukazuje živý přenos.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 16,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Center(child: _RoleBrandAccent()),
                    const SizedBox(height: 26),
                    VvText(
                      'ZPŮSOB PŘIPOJENÍ',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ConnectionModePicker(
                      selected: widget.connectionMode,
                      isPremium: widget.isPremium,
                      onSelected: widget.onConnectionModeChanged,
                    ),
                    const SizedBox(height: 22),
                    _RoleButton(
                      key: const Key('cameraRole'),
                      icon: Icons.videocam_rounded,
                      title: 'Kamera',
                      subtitle: 'Tento telefon snímá obraz a zvuk',
                      color: ViewVeeColors.teal,
                      selected: _selectedRole == DeviceRole.camera,
                      onTap: () => _selectRole(DeviceRole.camera),
                    ),
                    const SizedBox(height: 12),
                    _RoleButton(
                      key: const Key('monitorRole'),
                      icon: Icons.monitor_rounded,
                      title: 'Monitor',
                      subtitle: 'Tento telefon zobrazuje živý přenos',
                      color: ViewVeeColors.violet,
                      selected: _selectedRole == DeviceRole.monitor,
                      onTap: () => _selectRole(DeviceRole.monitor),
                    ),
                    const SizedBox(height: 20),
                    _RoleContinueButton(
                      onPressed: _selectedRole == null
                          ? null
                          : () => widget.onSelected(_selectedRole!),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_rounded,
                          size: 15,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: VvText(
                            'Přenos je šifrovaný end-to-end',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _selectRole(DeviceRole role) => setState(() => _selectedRole = role);
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedScale(
        scale: selected ? 1 : 0.985,
        duration: const Duration(milliseconds: 220),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.1)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? color : Theme.of(context).colorScheme.outline,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.14),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [color, color.withValues(alpha: 0.72)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: Colors.white, size: 27),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VvText(
                            title,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          VvText(
                            subtitle,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selected ? color : ViewVeeColors.outline,
                      size: 25,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionModePicker extends StatelessWidget {
  const _ConnectionModePicker({
    required this.selected,
    required this.isPremium,
    required this.onSelected,
  });

  final AudioConnectionMode selected;
  final bool isPremium;
  final ValueChanged<AudioConnectionMode> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Row(
      children: [
        Expanded(
          child: _ConnectionChoice(
            icon: Icons.wifi_rounded,
            label: 'Stejná Wi-Fi',
            selected: selected == AudioConnectionMode.wifi,
            onTap: () => onSelected(AudioConnectionMode.wifi),
          ),
        ),
        Expanded(
          child: _ConnectionChoice(
            icon: isPremium ? Icons.public_rounded : Icons.lock_outline_rounded,
            label: 'Internet',
            selected: selected == AudioConnectionMode.internet,
            onTap: () => onSelected(AudioConnectionMode.internet),
          ),
        ),
      ],
    ),
  );
}

class _ConnectionChoice extends StatelessWidget {
  const _ConnectionChoice({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    decoration: BoxDecoration(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 19,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: VvText(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RoleBrandAccent extends StatelessWidget {
  const _RoleBrandAccent();

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 4,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [ViewVeeColors.teal, ViewVeeColors.blue, ViewVeeColors.violet],
      ),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _RoleContinueButton extends StatelessWidget {
  const _RoleContinueButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    decoration: BoxDecoration(
      gradient: onPressed == null
          ? LinearGradient(
              colors: Theme.of(context).brightness == Brightness.dark
                  ? const [Color(0xFF26364D), Color(0xFF1B293C)]
                  : const [Color(0xFFB8C7D4), Color(0xFFD2D7E0)],
            )
          : const LinearGradient(
              colors: [
                ViewVeeColors.teal,
                ViewVeeColors.blue,
                ViewVeeColors.violet,
              ],
            ),
      borderRadius: BorderRadius.circular(8),
      boxShadow: onPressed == null
          ? null
          : [
              BoxShadow(
                color: ViewVeeColors.blue.withValues(alpha: 0.2),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('continueRole'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: const SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              VvText(
                'Pokračovat',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 10),
              Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 21),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AudioStatusBar extends StatelessWidget {
  const _AudioStatusBar({required this.state, required this.onReconnect});

  final AudioConnectionState state;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (state) {
      AudioConnectionState.idle => (
        'Zvuk není připojený',
        Icons.link_off_rounded,
        ViewVeeColors.violet,
      ),
      AudioConnectionState.creatingRoom => (
        'Vytvářím bezpečnou relaci',
        Icons.sync_rounded,
        ViewVeeColors.blue,
      ),
      AudioConnectionState.waitingForPeer => (
        'Čekám na druhý telefon',
        Icons.qr_code_rounded,
        ViewVeeColors.blue,
      ),
      AudioConnectionState.connecting => (
        'Navazuji šifrované spojení',
        Icons.sync_rounded,
        ViewVeeColors.blue,
      ),
      AudioConnectionState.connected => (
        'Zvuk je připojený',
        Icons.check_circle_rounded,
        ViewVeeColors.teal,
      ),
      AudioConnectionState.disconnected => (
        'Spojení bylo přerušeno',
        Icons.error_rounded,
        ViewVeeColors.violet,
      ),
      AudioConnectionState.error => (
        'Zvuk se nepodařilo připojit',
        Icons.error_rounded,
        ViewVeeColors.violet,
      ),
    };
    final canRetry =
        state == AudioConnectionState.idle ||
        state == AudioConnectionState.disconnected ||
        state == AudioConnectionState.error;
    final matchesCameraError = state == AudioConnectionState.idle;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: matchesCameraError ? null : color.withValues(alpha: 0.09),
        gradient: matchesCameraError
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  ViewVeeColors.blue.withValues(alpha: 0.14),
                  ViewVeeColors.violet.withValues(alpha: 0.12),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: matchesCameraError
              ? ViewVeeColors.violet.withValues(alpha: 0.34)
              : color.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: VvText(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (canRetry)
            IconButton(
              tooltip: context.vv('Připojit'),
              onPressed: onReconnect,
              color: color,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
    );
  }
}

class _AudioError extends StatelessWidget {
  const _AudioError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ViewVeeColors.blue.withValues(alpha: 0.14),
            ViewVeeColors.violet.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ViewVeeColors.violet.withValues(alpha: 0.34)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: ViewVeeColors.violet.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.info_outline_rounded,
              color: ViewVeeColors.violet,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: VvText(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({required this.pairingUri, required this.roomCode});

  final String pairingUri;
  final String roomCode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('cameraPairingQr'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ViewVeeColors.blue.withValues(alpha: 0.15),
            ViewVeeColors.violet.withValues(alpha: 0.11),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ViewVeeColors.blue.withValues(alpha: 0.32)),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.devices_rounded, color: ViewVeeColors.teal),
              SizedBox(width: 9),
              VvText(
                'Připojte druhý telefon',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 7),
          VvText(
            'Na telefonu, který bude sloužit jako monitor, '
            'zvolte Naskenovat QR kód.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: QrImageView(
              data: pairingUri,
              version: QrVersions.auto,
              size: 164,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF101C32),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.circle,
                color: Color(0xFF101C32),
              ),
            ),
          ),
          const SizedBox(height: 13),
          VvText(
            'Kód pro připojení',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          VvText(
            roomCode,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pairingUri));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: VvText('Párovací odkaz byl zkopírován.'),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded),
            label: const VvText('Kopírovat bezpečný odkaz'),
          ),
        ],
      ),
    );
  }
}

class _PairingScannerSheet extends StatefulWidget {
  const _PairingScannerSheet({required this.mode});

  final AudioConnectionMode mode;

  @override
  State<_PairingScannerSheet> createState() => _PairingScannerSheetState();
}

class _PairingScannerSheetState extends State<_PairingScannerSheet> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _found = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    final expectedMode = widget.mode == AudioConnectionMode.wifi
        ? AudioPairingMode.wifi
        : AudioPairingMode.internet;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null ||
          AudioPairingCredentials.tryParse(value, expectedMode: expectedMode) ==
              null) {
        continue;
      }
      _found = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.72,
      decoration: const BoxDecoration(
        color: Color(0xFF081525),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: VvText(
                      'Naskenovat QR kód kamery',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.vv('Zavřít'),
                    onPressed: () => Navigator.of(context).pop(),
                    color: Colors.white,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MobileScanner(
                        controller: _controller,
                        errorBuilder: (context, error, child) =>
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF0B1A2C),
                                    Color(0xFF142D45),
                                  ],
                                ),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.qr_code_scanner_rounded,
                                  color: ViewVeeColors.teal,
                                  size: 72,
                                ),
                              ),
                            ),
                        onDetect: _onDetect,
                      ),
                      Center(
                        child: IgnorePointer(
                          child: Container(
                            width: 230,
                            height: 230,
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white, width: 3),
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(28, 16, 28, 20),
              child: VvText(
                'Zamiřte na QR kód zobrazený na telefonu v režimu kamery.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFB8C6D8),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({
    required this.title,
    required this.connected,
    required this.overlay,
    this.reconnecting = false,
    this.renderer,
    this.mirror = false,
    this.nightMode = false,
    this.recording = false,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.recordingControl,
    this.qualityControl,
  });
  final String title;
  final bool connected;
  final bool reconnecting;
  final String overlay;
  final RTCVideoRenderer? renderer;
  final bool mirror;
  final bool nightMode;
  final bool recording;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;
  final Widget? recordingControl;
  final Widget? qualityControl;

  @override
  Widget build(BuildContext context) {
    final surface = Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ViewVeeColors.teal,
            ViewVeeColors.blue,
            ViewVeeColors.violet,
          ],
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0B1424),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: renderer != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ColorFiltered(
                        colorFilter: nightMode
                            ? const ColorFilter.matrix([
                                1.18,
                                0,
                                0,
                                0,
                                18,
                                0,
                                1.22,
                                0,
                                0,
                                22,
                                0,
                                0,
                                1.3,
                                0,
                                28,
                                0,
                                0,
                                0,
                                1,
                                0,
                              ])
                            : const ColorFilter.mode(
                                Colors.transparent,
                                BlendMode.dst,
                              ),
                        child: RTCVideoView(
                          renderer!,
                          mirror: mirror,
                          objectFit: fullscreen
                              ? RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitContain
                              : RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                        ),
                      ),
                    )
                  : Center(
                      child: Icon(
                        connected
                            ? Icons.videocam_rounded
                            : Icons.videocam_off_rounded,
                        size: 64,
                        color: Colors.white24,
                      ),
                    ),
            ),
            Positioned(
              left: 14,
              right: 8,
              top: 8,
              child: Row(
                children: [
                  Expanded(
                    child: VvText(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (qualityControl != null) ...[
                    if (overlay == 'Pouze zvuk')
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: VvText(
                          'Pouze zvuk',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    qualityControl!,
                  ] else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: VvText(
                        overlay,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (onToggleFullscreen != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: IconButton.filled(
                  key: Key(
                    fullscreen
                        ? 'exitMonitorFullscreen'
                        : 'enterMonitorFullscreen',
                  ),
                  tooltip: context.vv(
                    fullscreen ? 'Ukončit celou obrazovku' : 'Celá obrazovka',
                  ),
                  onPressed: onToggleFullscreen,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                  ),
                  icon: Icon(
                    fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                  ),
                ),
              ),
            if (recordingControl != null)
              Positioned(left: 8, bottom: 8, child: recordingControl!),
            if (recording && recordingControl == null)
              Positioned(
                left: 14,
                bottom: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD93445).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, color: Colors.white, size: 9),
                      SizedBox(width: 6),
                      VvText(
                        'NAHRÁVÁNÍ',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (!connected && reconnecting)
              const Center(
                child: VvText(
                  'Automaticky obnovuji spojení…',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            if (nightMode && !recording)
              Positioned(
                left: 14,
                bottom: recordingControl == null ? 14 : 66,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: ViewVeeColors.blue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: ViewVeeColors.teal.withValues(alpha: 0.45),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.nightlight_round,
                        color: ViewVeeColors.teal,
                        size: 14,
                      ),
                      SizedBox(width: 5),
                      VvText(
                        'NOČNÍ REŽIM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return fullscreen
        ? surface
        : AspectRatio(aspectRatio: 16 / 10, child: surface);
  }
}

class _RecordingControl extends StatelessWidget {
  const _RecordingControl({
    required this.recording,
    required this.busy,
    required this.elapsed,
    required this.locked,
    required this.enabled,
    required this.onLockedPressed,
    required this.onPressed,
  });

  final bool recording;
  final bool busy;
  final Duration elapsed;
  final bool locked;
  final bool enabled;
  final VoidCallback onLockedPressed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final actionEnabled = !busy && (locked || recording || enabled);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: Key(recording ? 'stopRecordingButton' : 'startRecordingButton'),
          tooltip: context.vv(
            recording
                ? 'Ukončit'
                : locked
                ? 'Nahrávání je součástí Premium'
                : 'Nahrávat',
          ),
          onPressed: actionEnabled
              ? recording
                    ? onPressed
                    : locked
                    ? onLockedPressed
                    : onPressed
              : null,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            minimumSize: const Size(36, 36),
            fixedSize: const Size(36, 36),
            tapTargetSize: MaterialTapTargetSize.padded,
            padding: const EdgeInsets.all(4),
            shape: const CircleBorder(
              side: BorderSide(color: Colors.white70, width: 1.5),
            ),
          ),
          icon: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      recording ? Icons.stop_rounded : Icons.circle,
                      size: 22,
                      color: actionEnabled
                          ? const Color(0xFFE53935)
                          : const Color(0xFFE53935).withValues(alpha: 0.4),
                    ),
                    if (locked && !recording)
                      const Icon(
                        Icons.lock_outline_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                  ],
                ),
        ),
        if (recording) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              _formatDuration(elapsed),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    final minuteSeconds =
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return hours == 0
        ? minuteSeconds
        : '${hours.toString().padLeft(2, '0')}:$minuteSeconds';
  }
}

class _ToggleControl extends StatelessWidget {
  const _ToggleControl({
    required this.icon,
    required this.label,
    required this.accentColor,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String label;
  final Color accentColor;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: value
              ? accentColor.withValues(alpha: 0.65)
              : Theme.of(context).colorScheme.outline,
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: value
                ? accentColor
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: VvText(
              label,
              maxLines: 2,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: accentColor,
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  label,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 11),
                ),
                VvText(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
