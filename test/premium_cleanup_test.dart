import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/premium_cleanup.dart';

void main() {
  test('failed camera cleanup does not prevent connection teardown', () async {
    final actions = <String>[];
    await runPremiumCleanup([
      () async {
        actions.add('talkback');
        throw StateError('disconnected');
      },
      () async => actions.add('recording'),
      () async {
        actions.add('quality');
        throw StateError('camera did not respond');
      },
      () async => actions.add('directory stop'),
      () async => actions.add('monitor stop'),
    ]);
    expect(actions, [
      'talkback',
      'recording',
      'quality',
      'directory stop',
      'monitor stop',
    ]);
  });
}
