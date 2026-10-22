import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Reopens native capture because flutter_webrtc's native applyConstraints
/// ignores video dimensions. The audio stream and negotiated sender stay alive.
class CameraVideoController {
  CameraVideoController({
    required this.stream,
    required this.sender,
    this.senders,
    required this.isHd,
    required this.capture,
    required this.onTrackChanged,
  });

  final MediaStream stream;
  RTCRtpSender sender;
  final Iterable<RTCRtpSender> Function()? senders;
  bool isHd;
  bool useFrontCamera = false;
  final Future<MediaStream> Function(Map<String, dynamic>) capture;
  final void Function() onTrackChanged;
  Future<void>? _pending;

  Future<void> get settled => _pending ?? Future<void>.value();

  static Map<String, dynamic> constraints({
    required bool isHd,
    required bool useFrontCamera,
  }) => {
    'facingMode': useFrontCamera ? 'user' : 'environment',
    // Numeric constraints work on both Android and iOS native capturers.
    'width': isHd ? 1280 : 640,
    'height': isHd ? 720 : 480,
    'frameRate': isHd ? 24 : 15,
  };

  Future<void> setQuality(bool value) {
    final operation = settled.then((_) async {
      if (value != isHd) await _changeQuality(value);
    });
    // Keep the queue usable after a failed change; the caller still gets the
    // original failure through operation.
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _changeQuality(bool value) async {
    final oldTrack = stream.getVideoTracks().first;
    // Release capture first: Android otherwise reuses the old camera format.
    await oldTrack.stop();
    await stream.removeTrack(oldTrack);
    try {
      await _open(value);
    } catch (_) {
      // Restore a usable video track if capture or replacement fails.
      await _open(isHd);
      rethrow;
    }
    isHd = value;
  }

  Future<void> _open(bool value) async {
    final replacement = await capture({
      'audio': false,
      'video': constraints(isHd: value, useFrontCamera: useFrontCamera),
    });
    final track = replacement.getVideoTracks().first;
    try {
      final targets = (senders?.call() ?? [sender]).toList();
      for (final target in targets) {
        await target.replaceTrack(track);
      }
      await stream.addTrack(track);
      // Transfer ownership before disposing the temporary stream.
      await replacement.removeTrack(track);
    } catch (_) {
      await stream.removeTrack(track);
      await track.stop();
      rethrow;
    } finally {
      await replacement.dispose();
    }
    onTrackChanged();
  }
}
