import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/frame_motion_detector.dart';

void main() {
  test('first and unchanged frames do not report motion', () {
    final detector = FrameMotionDetector(maxSamples: 100);
    final frame = Uint8List(1000);

    expect(detector.addFrame(frame, sensitivity: 2), isFalse);
    expect(detector.addFrame(frame, sensitivity: 2), isFalse);
  });

  test('large visual change reports motion', () {
    final detector = FrameMotionDetector(maxSamples: 100);
    detector.addFrame(Uint8List(1000), sensitivity: 0);

    expect(
      detector.addFrame(
        Uint8List(1000)..fillRange(0, 300, 255),
        sensitivity: 0,
      ),
      isTrue,
    );
  });

  test('sensitivity changes the required changed area', () {
    final low = FrameMotionDetector(maxSamples: 100);
    final high = FrameMotionDetector(maxSamples: 100);
    final baseline = Uint8List(1000);
    final changed = Uint8List(1000)..fillRange(0, 100, 255);
    low.addFrame(baseline, sensitivity: 0);
    high.addFrame(baseline, sensitivity: 2);

    expect(low.addFrame(changed, sensitivity: 0), isFalse);
    expect(high.addFrame(changed, sensitivity: 2), isTrue);
  });
}
