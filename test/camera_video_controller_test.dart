import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:viewvee/audio/camera_video_controller.dart';

void main() {
  test(
    'quality replaces sent video, preserves audio and selected camera',
    () async {
      final audio = _Track('audio');
      final oldVideo = _Track('video');
      final stream = _Stream([audio, oldVideo]);
      final sender = _Sender()..current = oldVideo;
      final captures = <Map<String, dynamic>>[];
      var previews = 0;
      final camera = CameraVideoController(
        stream: stream,
        sender: sender,
        isHd: false,
        capture: (constraints) async {
          expect(stream.getVideoTracks(), isEmpty);
          captures.add(constraints);
          return _Stream([_Track('video')]);
        },
        onTrackChanged: () => previews++,
      )..useFrontCamera = true;

      await camera.setQuality(true);
      expect(oldVideo.stopped, isTrue);
      expect(audio.stopped, isFalse);
      expect(stream.getAudioTracks(), [audio]);
      expect(sender.current, same(stream.getVideoTracks().single));
      expect((sender.current as _Track).stopped, isFalse);
      expect(captures.single, {
        'audio': false,
        'video': {
          'facingMode': 'user',
          'width': 1280,
          'height': 720,
          'frameRate': 24,
        },
      });
      expect(camera.isHd, isTrue);

      await camera.setQuality(false);
      expect(captures.last['video']['height'], 480);
      expect(camera.isHd, isFalse);
      expect(previews, 2);
      expect(audio.stopped, isFalse);
    },
  );

  for (final failReplacement in [false, true]) {
    test(
      'restores video when ${failReplacement ? 'sender' : 'capture'} fails',
      () async {
        final stream = _Stream([_Track('audio'), _Track('video')]);
        final sender = _Sender()..failNext = failReplacement;
        var attempts = 0;
        final camera = CameraVideoController(
          stream: stream,
          sender: sender,
          isHd: false,
          capture: (constraints) async {
            attempts++;
            if (!failReplacement && attempts == 1) throw StateError('capture');
            return _Stream([_Track('video')]);
          },
          onTrackChanged: () {},
        );

        await expectLater(camera.setQuality(true), throwsStateError);
        expect(attempts, 2);
        expect(camera.isHd, isFalse);
        expect(sender.current, same(stream.getVideoTracks().single));
        expect((sender.current as _Track).stopped, isFalse);
        await camera.setQuality(true);
        expect(camera.isHd, isTrue);
      },
    );
  }

  test('restores every viewer after a partial quality update fails', () async {
    final stream = _Stream([_Track('audio'), _Track('video')]);
    final first = _Sender();
    final second = _Sender()..failNext = true;
    final camera = CameraVideoController(
      stream: stream,
      sender: first,
      senders: () => [first, second],
      isHd: false,
      capture: (_) async => _Stream([_Track('video')]),
      onTrackChanged: () {},
    );
    await expectLater(camera.setQuality(true), throwsStateError);
    expect(camera.isHd, isFalse);
    expect(first.current, same(stream.getVideoTracks().single));
    expect(second.current, same(first.current));
    expect((first.current as _Track).stopped, isFalse);
  });

  test('serializes rapid quality changes', () async {
    final stream = _Stream([_Track('video')]);
    var activeCaptures = 0;
    final camera = CameraVideoController(
      stream: stream,
      sender: _Sender(),
      isHd: false,
      capture: (_) async {
        activeCaptures++;
        expect(activeCaptures, 1);
        await Future<void>.delayed(Duration.zero);
        activeCaptures--;
        return _Stream([_Track('video')]);
      },
      onTrackChanged: () {},
    );
    await Future.wait([
      camera.setQuality(true),
      camera.setQuality(false),
      camera.setQuality(true),
    ]);
    expect(camera.isHd, isTrue);
    expect(stream.getVideoTracks(), hasLength(1));
  });
}

class _Track extends Fake implements MediaStreamTrack {
  _Track(this.kind);
  @override
  final String kind;
  bool stopped = false;
  @override
  Future<void> stop() async => stopped = true;
}

class _Stream extends Fake implements MediaStream {
  _Stream(this.tracks);
  final List<MediaStreamTrack> tracks;
  @override
  List<MediaStreamTrack> getVideoTracks() =>
      tracks.where((t) => t.kind == 'video').toList();
  @override
  List<MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();
  @override
  Future<void> addTrack(
    MediaStreamTrack track, {
    bool addToNative = true,
  }) async => tracks.add(track);
  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) async => tracks.remove(track);
  @override
  Future<void> dispose() async {
    for (final track in tracks) {
      await track.stop();
    }
  }
}

class _Sender extends Fake implements RTCRtpSender {
  MediaStreamTrack? current;
  bool failNext = false;
  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async {
    if (failNext) {
      failNext = false;
      throw StateError('replace');
    }
    current = track;
  }
}
