import 'package:flutter/material.dart';

import '../audio/audio_monitor_service.dart';
import '../monitor/saved_camera_repository.dart';
import '../theme/viewvee_theme.dart';

class SavedCameraList extends StatefulWidget {
  const SavedCameraList({
    super.key,
    required this.cameras,
    required this.selectedId,
    required this.stateOf,
    required this.onSelect,
    required this.onAdd,
    required this.onRefresh,
    required this.onRename,
    required this.onRemove,
    this.busy = false,
    this.isLocked,
    this.addLocked = false,
    this.lockedLabel = 'Premium',
  });

  final List<SavedCamera> cameras;
  final String? selectedId;
  final AudioConnectionState Function(String) stateOf;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;
  final ValueChanged<SavedCamera> onRename;
  final ValueChanged<String> onRemove;
  final bool busy;
  final bool Function(String)? isLocked;
  final bool addLocked;
  final String lockedLabel;

  @override
  State<SavedCameraList> createState() => _SavedCameraListState();
}

class _SavedCameraListState extends State<SavedCameraList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cameras = widget.cameras;
    final selectedId = widget.selectedId;
    final stateOf = widget.stateOf;
    final busy = widget.busy;
    final onRefresh = widget.onRefresh;
    final onAdd = widget.onAdd;
    final onRename = widget.onRename;
    final onRemove = widget.onRemove;
    final selected = cameras
        .where((camera) => camera.id == selectedId)
        .firstOrNull;
    final state = selected == null ? null : stateOf(selected.id);
    final active = state == AudioConnectionState.connected;
    final connecting =
        state == AudioConnectionState.connecting ||
        state == AudioConnectionState.creatingRoom ||
        state == AudioConnectionState.waitingForPeer;
    final status = active
        ? 'Aktivní'
        : connecting
        ? 'Připojuji…'
        : 'Neaktivní';
    final statusColor = active
        ? ViewVeeColors.teal
        : connecting
        ? ViewVeeColors.blue
        : colors.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: _expanded,
            child: ListTile(
              key: const Key('cameraListToggle'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              minLeadingWidth: 20,
              leading: Icon(
                Icons.videocam_outlined,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
              title: Text(
                selected == null
                    ? context.vv('Moje kamery')
                    : selected.name ??
                          '${context.vv('Kamera')} ${selected.roomCode}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected != null) ...[
                    Icon(Icons.circle, size: 6, color: statusColor),
                    const SizedBox(width: 5),
                    VvText(
                      status,
                      style: TextStyle(fontSize: 12, color: statusColor),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                  ),
                ],
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded) ...[
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Expanded(
                    child: VvText(
                      'Moje kamery',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : onRefresh,
                    tooltip: context.vv('Obnovit seznam'),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    onPressed: busy ? null : onAdd,
                    tooltip: context.vv('Spárovat kameru'),
                    icon: Icon(
                      widget.addLocked
                          ? Icons.lock_outline_rounded
                          : Icons.add_rounded,
                    ),
                  ),
                ],
              ),
            ),
            if (cameras.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: VvText('Zatím nemáte spárovanou kameru.'),
              ),
            for (final camera in cameras)
              Builder(
                builder: (context) {
                  final state = stateOf(camera.id);
                  final locked = widget.isLocked?.call(camera.id) ?? false;
                  final active = state == AudioConnectionState.connected;
                  final connecting =
                      state == AudioConnectionState.connecting ||
                      state == AudioConnectionState.creatingRoom ||
                      state == AudioConnectionState.waitingForPeer;
                  final color = active
                      ? ViewVeeColors.teal
                      : connecting
                      ? ViewVeeColors.blue
                      : colors.onSurfaceVariant;
                  return ListTile(
                    key: ValueKey(camera.id),
                    selected: selectedId == camera.id,
                    selectedTileColor: ViewVeeColors.teal.withValues(
                      alpha: 0.08,
                    ),
                    leading: Icon(
                      locked
                          ? Icons.lock_outline_rounded
                          : active
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                      color: color,
                    ),
                    title: Text(
                      camera.name ??
                          '${context.vv('Kamera')} ${camera.roomCode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Row(
                      children: [
                        Icon(Icons.circle, size: 8, color: color),
                        const SizedBox(width: 6),
                        Flexible(
                          child: VvText(
                            locked
                                ? widget.lockedLabel
                                : active
                                ? 'Aktivní'
                                : connecting
                                ? 'Připojuji…'
                                : 'Neaktivní',
                            style: TextStyle(color: color),
                          ),
                        ),
                      ],
                    ),
                    dense: true,
                    onTap: busy
                        ? null
                        : () {
                            widget.onSelect(camera.id);
                            setState(() => _expanded = false);
                          },
                    trailing: PopupMenuButton<String>(
                      enabled: !busy,
                      onSelected: (action) {
                        if (action == 'rename') onRename(camera);
                        if (action == 'remove') onRemove(camera.id);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'rename',
                          child: VvText('Přejmenovat kameru'),
                        ),
                        PopupMenuItem(value: 'remove', child: VvText('Smazat')),
                      ],
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}
