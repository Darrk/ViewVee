import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../recordings/recording_repository.dart';
import '../theme/viewvee_theme.dart';

class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key, this.repository, this.initialRecordings});

  final RecordingRepository? repository;
  final List<ViewveeRecording>? initialRecordings;

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late final RecordingRepository _repository;
  late Future<List<ViewveeRecording>> _recordings;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RecordingRepository();
    _recordings = widget.initialRecordings == null
        ? _repository.loadRecordings()
        : Future.value(widget.initialRecordings);
  }

  void _reload() => _recordings = _repository.loadRecordings();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ViewveeRecording>>(
    future: _recordings,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final recordings = snapshot.data!;
      return RefreshIndicator(
        onRefresh: () async {
          setState(_reload);
          await _recordings;
        },
        child: ListView(
          key: const Key('recordingsPage'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          children: [
            const _RecordingsIntro(),
            const SizedBox(height: 20),
            if (recordings.isEmpty)
              const _EmptyRecordings()
            else
              for (final recording in recordings) ...[
                _RecordingCard(
                  recording: recording,
                  onPlay: () => _play(recording),
                  onShare: (origin) => _share(recording, origin),
                  onDelete: () => _delete(recording),
                ),
                const SizedBox(height: 12),
              ],
          ],
        ),
      );
    },
  );

  Future<void> _play(ViewveeRecording recording) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RecordingPlayerScreen(recording: recording),
      ),
    );
  }

  Future<void> _share(ViewveeRecording recording, Rect origin) async {
    await SharePlus.instance.share(
      ShareParams(
        title: context.vv('Nahrávka ViewVee'),
        subject: context.vv('Nahrávka ViewVee'),
        text: context.vv('Nahrávka ViewVee'),
        files: [XFile(recording.path, mimeType: 'video/mp4')],
        sharePositionOrigin: origin,
      ),
    );
  }

  Future<void> _delete(ViewveeRecording recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const VvText('Smazat nahrávku?'),
        content: const VvText(
          'Nahrávka bude trvale odstraněna z tohoto telefonu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VvText('Zrušit'),
          ),
          FilledButton(
            key: const Key('confirmDeleteRecording'),
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const VvText('Smazat'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.delete(recording);
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: VvText('Nahrávka byla smazána.')));
  }
}

class _RecordingsIntro extends StatelessWidget {
  const _RecordingsIntro();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surface,
            ViewveeColors.blue.withValues(alpha: 0.12),
            ViewveeColors.violet.withValues(alpha: 0.09),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ViewveeColors.blue.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [ViewveeColors.teal, ViewveeColors.blue],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.video_library_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VvText(
                  'Vaše nahrávky',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                VvText(
                  'Záznamy jsou uložené bezpečně v tomto telefonu.',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRecordings extends StatelessWidget {
  const _EmptyRecordings();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: Column(
      children: [
        const Icon(
          Icons.videocam_off_outlined,
          size: 46,
          color: ViewveeColors.blue,
        ),
        const SizedBox(height: 14),
        VvText(
          'Zatím žádné nahrávky',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        VvText(
          'Nahrávání můžete spustit na obrazovce kamery nebo monitoru.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({
    required this.recording,
    required this.onPlay,
    required this.onShare,
    required this.onDelete,
  });

  final ViewveeRecording recording;
  final VoidCallback onPlay;
  final ValueChanged<Rect> onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey(recording.path),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: InkWell(
      onTap: onPlay,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 70,
              height: 58,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF123C42), Color(0xFF173652)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.play_circle_fill_rounded,
                color: ViewveeColors.teal,
                size: 32,
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VvText(
                    recording.source == RecordingSource.camera
                        ? 'Kamera'
                        : 'Monitor',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  VvText(
                    '${_date(context, recording.createdAt)}  •  '
                    '${_duration(recording.duration)}  •  '
                    '${_size(context, recording.sizeBytes)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Builder(
              builder: (buttonContext) => PopupMenuButton<String>(
                tooltip: context.vv('Možnosti nahrávky'),
                onSelected: (value) {
                  if (value == 'share') {
                    final box = buttonContext.findRenderObject() as RenderBox?;
                    if (box != null) {
                      onShare(box.localToGlobal(Offset.zero) & box.size);
                    }
                  } else if (value == 'delete') {
                    onDelete();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'share',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.ios_share_rounded),
                      title: VvText('Uložit nebo sdílet'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded),
                      title: VvText('Smazat'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  static String _date(BuildContext context, DateTime value) => DateFormat.yMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).add_Hm().format(value);

  static String _duration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String _size(BuildContext context, int bytes) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (bytes < 1024 * 1024) {
      return '${NumberFormat('0', locale).format(bytes / 1024)} kB';
    }
    return '${NumberFormat('0.0', locale).format(bytes / (1024 * 1024))} MB';
  }
}

class _RecordingPlayerScreen extends StatefulWidget {
  const _RecordingPlayerScreen({required this.recording});

  final ViewveeRecording recording;

  @override
  State<_RecordingPlayerScreen> createState() => _RecordingPlayerScreenState();
}

class _RecordingPlayerScreenState extends State<_RecordingPlayerScreen> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialized;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.recording.path));
    _initialized = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const VvText('Nahrávka')),
    body: SafeArea(
      child: FutureBuilder<void>(
        future: _initialized,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: VvText('Nahrávku se nepodařilo otevřít.'),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                ),
              ),
              VideoProgressIndicator(
                _controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: ViewveeColors.teal,
                  bufferedColor: ViewveeColors.blue,
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: _controller,
                builder: (context, value, _) => FilledButton.icon(
                  onPressed: () => value.isPlaying
                      ? _controller.pause()
                      : _controller.play(),
                  icon: Icon(
                    value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  label: VvText(value.isPlaying ? 'Pozastavit' : 'Přehrát'),
                ),
              ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    ),
  );
}
