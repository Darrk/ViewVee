import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum RecordingSource { camera, monitor }

class ViewveeRecording {
  const ViewveeRecording({
    required this.path,
    required this.source,
    required this.createdAt,
    required this.duration,
    required this.sizeBytes,
  });

  final String path;
  final RecordingSource source;
  final DateTime createdAt;
  final Duration duration;
  final int sizeBytes;

  String get fileName => path.split(Platform.pathSeparator).last;
}

typedef RecordingDirectoryProvider = Future<Directory> Function();

class RecordingRepository {
  RecordingRepository({RecordingDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final RecordingDirectoryProvider _directoryProvider;

  Future<String> createPath(RecordingSource source) async {
    final directory = await _directory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${directory.path}${Platform.pathSeparator}'
        'viewvee_${source.name}_$timestamp.mp4';
  }

  Future<void> saveMetadata({
    required String path,
    required RecordingSource source,
    required DateTime createdAt,
    required Duration duration,
  }) async {
    final metadata = File(_metadataPath(path));
    await metadata.writeAsString(
      jsonEncode({
        'source': source.name,
        'createdAt': createdAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
      }),
      flush: true,
    );
  }

  Future<List<ViewveeRecording>> loadRecordings() async {
    final directory = await _directory();
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.mp4'))
        .cast<File>()
        .toList();
    final recordings = <ViewveeRecording>[];
    for (final file in files) {
      final stat = await file.stat();
      if (stat.size == 0) continue;
      final fallback = _fallbackMetadata(file.path, stat.modified);
      var source = fallback.source;
      var createdAt = fallback.createdAt;
      var duration = Duration.zero;
      final metadata = File(_metadataPath(file.path));
      if (await metadata.exists()) {
        try {
          final decoded = jsonDecode(await metadata.readAsString());
          if (decoded is Map) {
            source = RecordingSource.values.firstWhere(
              (value) => value.name == decoded['source'],
              orElse: () => source,
            );
            createdAt =
                DateTime.tryParse(decoded['createdAt']?.toString() ?? '') ??
                createdAt;
            final durationMs = decoded['durationMs'];
            if (durationMs is int && durationMs >= 0) {
              duration = Duration(milliseconds: durationMs);
            }
          }
        } catch (_) {
          // A recording remains usable even if its optional metadata is broken.
        }
      }
      recordings.add(
        ViewveeRecording(
          path: file.path,
          source: source,
          createdAt: createdAt,
          duration: duration,
          sizeBytes: stat.size,
        ),
      );
    }
    recordings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return recordings;
  }

  Future<void> delete(ViewveeRecording recording) async {
    final video = File(recording.path);
    final metadata = File(_metadataPath(recording.path));
    if (await video.exists()) await video.delete();
    if (await metadata.exists()) await metadata.delete();
  }

  Future<Directory> _directory() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}ViewVee${Platform.pathSeparator}Recordings',
    );
  }

  static String _metadataPath(String path) => '$path.json';

  static ({RecordingSource source, DateTime createdAt}) _fallbackMetadata(
    String path,
    DateTime modified,
  ) {
    final name = path.split(Platform.pathSeparator).last;
    final parts = name.replaceAll('.mp4', '').split('_');
    final source = parts.contains(RecordingSource.monitor.name)
        ? RecordingSource.monitor
        : RecordingSource.camera;
    final timestamp = int.tryParse(parts.isEmpty ? '' : parts.last);
    return (
      source: source,
      createdAt: timestamp == null
          ? modified
          : DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }
}
