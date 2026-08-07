import 'dart:typed_data';

class FrameMotionDetector {
  FrameMotionDetector({this.maxSamples = 4096});

  final int maxSamples;
  Uint8List? _previousFrame;

  bool addFrame(Uint8List frame, {required int sensitivity}) {
    if (frame.isEmpty) return false;
    final previous = _previousFrame;
    _previousFrame = Uint8List.fromList(frame);
    if (previous == null || previous.length != frame.length) return false;

    final step = (frame.length / maxSamples).ceil().clamp(1, frame.length);
    var changed = 0;
    var samples = 0;
    for (var index = 0; index < frame.length; index += step) {
      samples += 1;
      if ((frame[index] - previous[index]).abs() >= 24) changed += 1;
    }
    final changedRatio = changed / samples;
    final threshold = switch (sensitivity.clamp(0, 2)) {
      0 => 0.18,
      1 => 0.11,
      _ => 0.06,
    };
    return changedRatio >= threshold;
  }

  void reset() => _previousFrame = null;
}
