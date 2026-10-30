import 'package:flutter/material.dart';

import '../audio/audio_pairing.dart';
import '../audio/camera_pairing_repository.dart';
import '../monitor/saved_camera_repository.dart';
import '../theme/viewvee_theme.dart';

/// Shows saved pairings across both roles and connection modes. Saved pairings
/// do not imply that the remote device is currently online.
class PairedDeviceList extends StatefulWidget {
  const PairedDeviceList({super.key});

  @override
  State<PairedDeviceList> createState() => _PairedDeviceListState();
}

class _PairedDeviceListState extends State<PairedDeviceList> {
  late Future<List<List<SavedCamera>>> _devices;

  @override
  void initState() {
    super.initState();
    _devices = _load();
    SavedCameraRepository.changes.addListener(_refresh);
  }

  Future<List<List<SavedCamera>>> _load() => Future.wait([
    SavedCameraRepository().load(),
    CameraPairingRepository().loadDevices(),
  ]);

  void _refresh() {
    final devices = _load();
    setState(() {
      _devices = devices;
    });
  }

  @override
  void dispose() {
    SavedCameraRepository.changes.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<List<SavedCamera>>>(
    future: _devices,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return Column(
          children: [
            const VvText('Něco se pokazilo. Zkuste to prosím znovu.'),
            TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const VvText('Obnovit seznam'),
            ),
          ],
        );
      }
      final cameras = snapshot.data![0];
      final monitors = snapshot.data![1];
      if (cameras.isEmpty && monitors.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: VvText('Zatím nemáte spárované zařízení.'),
        );
      }
      return Column(
        children: [
          for (final camera in cameras) _device(camera, isCamera: true),
          for (final monitor in monitors) _device(monitor, isCamera: false),
        ],
      );
    },
  );

  Widget _device(SavedCamera device, {required bool isCamera}) {
    final role = context.vv(isCamera ? 'Kamera' : 'Monitor');
    return ListTile(
      key: ValueKey('paired-${isCamera ? 'camera' : 'monitor'}-${device.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        isCamera ? Icons.videocam_rounded : Icons.monitor_rounded,
        color: isCamera ? ViewVeeColors.teal : ViewVeeColors.blue,
      ),
      title: Text(device.name ?? '$role ${device.roomCode}'),
      subtitle: Text(
        '$role • ${context.vv(device.mode == AudioPairingMode.wifi ? 'Stejná Wi‑Fi' : 'Internet')}',
      ),
    );
  }
}
