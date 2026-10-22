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
import '../monitor/monitor_settings.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  static const _activeRoleKey = 'monitor.activeRole';
  static const _activeModeKey = 'monitor.activeMode';
  final _pairingRepository = AudioPairingRepository();
  late AudioMonitorService _audioMonitor;
  final _settingsRepository = MonitorSettingsRepository();
  final _notificationService = MonitorNotificationService();
  final _recordingRepository = RecordingRepository();
  late AudioConnectionMode _connectionMode;
  DeviceRole? _role;
  bool _frontCamera = false;
  late bool _isHd;
  late bool _isPremium;
  bool _flash = false;
  bool _nightMode = false;
  bool _microphone = false;
  bool _audioBusy = false;
  bool _backgroundBusy = false;
  AudioConnectionState _audioState = AudioConnectionState.idle;
  String? _pairingUri;
  String? _roomCode;
  String? _audioError;
  bool _motionNotification = true;
  bool _soundNotification = true;
  bool _connectionNotification = true;
  double _sensitivity = 1;
  MonitorTelemetry _telemetry = const MonitorTelemetry();
  Timer? _recordingTimer;
  DateTime? _recordingStartedAt;
  RecordingSource? _recordingSource;
  String? _recordingPath;
  Duration _recordingElapsed = Duration.zero;
  bool _recordingBusy = false;

  @override
  void initState() {
    super.initState();
    _isPremium = widget.isPremium;
    _isHd = _isPremium;
    _connectionMode = _isPremium
        ? AudioConnectionMode.internet
        : AudioConnectionMode.wifi;
    _createAudioMonitor();
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

  void _createAudioMonitor() {
    _audioMonitor = AudioMonitorService(mode: _connectionMode);
    _audioMonitor.onStateChanged = (state) {
      if (!mounted) return;
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
    };
    _audioMonitor.onRemoteHangup = () {
      if (!mounted) return;
      setState(() => _audioError = 'Druhé zařízení se odpojilo.');
      if (_connectionNotification) {
        unawaited(
          _notificationService.show(MonitorNotificationType.connectionLost),
        );
      }
    };
    _audioMonitor.onError = (error) {
      if (!mounted) return;
      setState(() => _audioError = error.toString());
    };
    _audioMonitor.onTelemetry = (telemetry) {
      if (mounted) setState(() => _telemetry = telemetry);
    };
    _audioMonitor.onDetection = (event) {
      final type = switch (event) {
        MonitorDetectionEvent.motion when _motionNotification =>
          MonitorNotificationType.motion,
        MonitorDetectionEvent.sound when _soundNotification =>
          MonitorNotificationType.sound,
        _ => null,
      };
      if (type != null) unawaited(_notificationService.show(type));
    };
    unawaited(_syncDetectionSettings());
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsRepository.load();
    if (!mounted) return;
    setState(() {
      _motionNotification = settings.motionEnabled;
      _soundNotification = settings.soundEnabled;
      _connectionNotification = settings.connectionEnabled;
      _sensitivity = settings.sensitivity.toDouble();
    });
    await _syncDetectionSettings();
  }

  Future<void> _saveSettings() async {
    await _settingsRepository.save(
      MonitorSettings(
        motionEnabled: _motionNotification,
        soundEnabled: _soundNotification,
        connectionEnabled: _connectionNotification,
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
    _recordingTimer?.cancel();
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
    _audioMonitor.onDetection = null;
    unawaited(_audioMonitor.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
      await _stopRecording(showMessage: false);
      await _audioMonitor.setVideoQuality(isHd: false);
    }
    if (mustLeaveInternet) {
      _audioMonitor.onStateChanged = null;
      _audioMonitor.onRemoteHangup = null;
      _audioMonitor.onError = null;
      await _audioMonitor.stop();
    }
    if (!mounted) return;
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
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _AudioStatusBar(state: _audioState, onReconnect: _startTransmitter),
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
          overlay: _isHd ? 'HD 720p' : 'SD 480p',
          renderer: _audioMonitor.localVideoRenderer,
          mirror: _frontCamera,
          nightMode: _nightMode,
          recording: _recordingStartedAt != null,
        ),
        const SizedBox(height: 12),
        _RecordingControl(
          recording: _recordingStartedAt != null,
          busy: _recordingBusy,
          elapsed: _recordingElapsed,
          locked: !_isPremium,
          enabled: !_audioBusy && _audioMonitor.canRecord,
          onLockedPressed: _showRecordingPremiumRequired,
          onPressed: _recordingStartedAt == null
              ? () => _startRecording(RecordingSource.camera)
              : _stopRecording,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<bool>(
                segments: [
                  const ButtonSegment(value: false, label: VvText('SD')),
                  ButtonSegment(
                    value: true,
                    icon: Icon(
                      _isPremium
                          ? Icons.hd_rounded
                          : Icons.lock_outline_rounded,
                      size: 17,
                    ),
                    label: const VvText('HD', key: Key('hdQualityOption')),
                  ),
                ],
                selected: {_isHd},
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? ViewVeeColors.teal.withValues(alpha: 0.18)
                        : colors.surface,
                  ),
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? ViewVeeColors.teal
                        : colors.onSurfaceVariant,
                  ),
                  side: WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color: states.contains(WidgetState.selected)
                          ? ViewVeeColors.teal
                          : colors.outline,
                    ),
                  ),
                ),
                onSelectionChanged: (value) async {
                  final isHd = value.first;
                  if (isHd && !_isPremium) {
                    await _showHdPremiumRequired();
                    return;
                  }
                  await _audioMonitor.setVideoQuality(isHd: isHd);
                  if (mounted) setState(() => _isHd = isHd);
                },
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filledTonal(
              tooltip: context.vv('Přepnout kameru'),
              onPressed: () async {
                if (_flash) await _audioMonitor.setTorchEnabled(false);
                await _audioMonitor.switchCamera();
                if (mounted) {
                  setState(() {
                    _frontCamera = !_frontCamera;
                    _flash = false;
                  });
                }
              },
              icon: const Icon(Icons.cameraswitch_rounded),
              style: IconButton.styleFrom(
                backgroundColor: ViewVeeColors.blue.withValues(alpha: 0.16),
                foregroundColor: ViewVeeColors.blue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed:
              _audioState == AudioConnectionState.connected ||
                  _audioState == AudioConnectionState.waitingForPeer
              ? () {
                  setState(() => _microphone = !_microphone);
                  _audioMonitor.setTransmitterMuted(_microphone);
                }
              : null,
          icon: Icon(_microphone ? Icons.mic_off_rounded : Icons.mic_rounded),
          label: VvText(_microphone ? 'Zapnout zvuk' : 'Ztlumit'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ToggleControl(
                icon: Icons.flashlight_on_rounded,
                label: 'Svítilna',
                accentColor: ViewVeeColors.teal,
                value: _flash,
                onChanged: (value) async {
                  if (_frontCamera && value) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: VvText(
                          'Svítilna je dostupná pouze u zadní kamery.',
                        ),
                      ),
                    );
                    return;
                  }
                  final supported = await _audioMonitor.setTorchEnabled(value);
                  if (!mounted) return;
                  if (!supported) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: VvText(
                          'Svítilna není na této kameře dostupná.',
                        ),
                      ),
                    );
                    return;
                  }
                  setState(() => _flash = value);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ToggleControl(
                icon: Icons.dark_mode_rounded,
                label: 'Noční režim',
                accentColor: ViewVeeColors.blue,
                value: _nightMode,
                onChanged: (value) async {
                  final available = await _audioMonitor.setNightModeEnabled(
                    value,
                  );
                  if (!mounted) return;
                  if (!available) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: VvText('Nejprve spusťte kameru.'),
                      ),
                    );
                    return;
                  }
                  setState(() => _nightMode = value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _changeRoleButton(),
      ],
    );
  }

  Widget _monitorView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _AudioStatusBar(state: _audioState, onReconnect: _showPairingOptions),
        if (_audioError != null) _AudioError(message: _audioError!),
        const SizedBox(height: 12),
        _VideoSurface(
          title: _modeLabel,
          connected: _audioState == AudioConnectionState.connected,
          overlay: '${_isPremium ? 'HD' : 'SD'} • Šifrováno',
          renderer: _audioMonitor.remoteVideoRenderer,
          recording: _recordingStartedAt != null,
        ),
        const SizedBox(height: 12),
        _RecordingControl(
          recording: _recordingStartedAt != null,
          busy: _recordingBusy,
          elapsed: _recordingElapsed,
          locked: !_isPremium,
          enabled:
              _audioState == AudioConnectionState.connected &&
              _audioMonitor.canRecord,
          onLockedPressed: _showRecordingPremiumRequired,
          onPressed: _recordingStartedAt == null
              ? () => _startRecording(RecordingSource.monitor)
              : _stopRecording,
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
          onPressed:
              _audioState == AudioConnectionState.connected && !_audioBusy
              ? _toggleTalkback
              : null,
          icon: Icon(_microphone ? Icons.mic_rounded : Icons.mic_off_rounded),
          label: VvText(_microphone ? 'Ztlumit' : 'Zapnout zvuk'),
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
    await _stopRecording(showMessage: false);
    if (_flash) await _audioMonitor.setTorchEnabled(false);
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
    });
  }

  Future<void> _startRecording(RecordingSource source) async {
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

  Future<void> _showPairingOptions() async {
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
      await _pairingRepository.rememberMonitor(pairingValue);
      final joined = await _audioMonitor.joinAsReceiver(pairingValue);
      if (!joined && mounted) {
        setState(() => _audioError = 'Kamera nebyla nalezena.');
      }
    } catch (error) {
      if (mounted) setState(() => _audioError = error.toString());
    } finally {
      if (mounted) setState(() => _audioBusy = false);
    }
  }

  Future<void> _toggleTalkback() async {
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
          VvText(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
    this.renderer,
    this.mirror = false,
    this.nightMode = false,
    this.recording = false,
  });
  final String title;
  final bool connected;
  final String overlay;
  final RTCVideoRenderer? renderer;
  final bool mirror;
  final bool nightMode;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Container(
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
                            objectFit: RTCVideoViewObjectFit
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
                top: 14,
                child: VvText(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Positioned(
                right: 14,
                top: 14,
                child: Container(
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
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
              if (recording)
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
              if (!connected)
                const Center(
                  child: VvText(
                    'Automaticky obnovuji spojení…',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              if (nightMode && !recording)
                Positioned(
                  left: 14,
                  bottom: 14,
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
      ),
    );
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
    final colors = Theme.of(context).colorScheme;
    final actionEnabled = !busy && (locked || recording || enabled);
    final accent = locked ? ViewVeeColors.violet : ViewVeeColors.blue;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: recording
            ? const Color(0xFFD93445).withValues(alpha: 0.1)
            : colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: recording
              ? const Color(0xFFD93445).withValues(alpha: 0.5)
              : colors.outline,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: recording
                  ? const Color(0xFFD93445).withValues(alpha: 0.16)
                  : accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              recording
                  ? Icons.stop_rounded
                  : locked
                  ? Icons.lock_outline_rounded
                  : Icons.fiber_manual_record,
              color: recording ? const Color(0xFFD93445) : accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  recording
                      ? 'NAHRÁVÁNÍ'
                      : locked
                      ? 'Nahrávání je součástí Premium'
                      : 'Nahrávka',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                VvText(
                  recording
                      ? _formatDuration(elapsed)
                      : locked
                      ? 'Zobrazit Premium'
                      : enabled
                      ? 'Nahrávky'
                      : 'Odpojeno',
                  style: TextStyle(
                    color: recording
                        ? const Color(0xFFD93445)
                        : colors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: recording ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          FilledButton(
            key: Key(
              recording ? 'stopRecordingButton' : 'startRecordingButton',
            ),
            onPressed: actionEnabled
                ? locked
                      ? onLockedPressed
                      : onPressed
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: recording ? const Color(0xFFD93445) : accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: VvText(
              recording
                  ? 'Ukončit'
                  : locked
                  ? 'Zobrazit Premium'
                  : 'Uložit',
            ),
          ),
        ],
      ),
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
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: value
              ? accentColor.withValues(alpha: 0.65)
              : Theme.of(context).colorScheme.outline,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: value
                ? accentColor
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          VvText(
            label,
            maxLines: 1,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
