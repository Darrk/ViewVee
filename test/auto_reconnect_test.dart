import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/audio/audio_monitor_service.dart';
import 'package:viewvee/audio/turn_credentials_service.dart';
import 'package:viewvee/audio/audio_signaling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Signaling signaling;
  late AudioMonitorService monitor;
  var connectionCount = 0;
  final channels = <MethodChannel>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    connectionCount = 0;
    channels.clear();
    void mock(
      MethodChannel channel,
      Future<Object?> Function(MethodCall) handler,
    ) {
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, handler);
    }

    mock(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      if (call.method == 'createPeerConnection') {
        final id = 'connection${++connectionCount}';
        mock(
          MethodChannel('FlutterWebRTC/peerConnectionEvent$id'),
          (_) async => null,
        );
        return {'peerConnectionId': id};
      }
      if (call.method == 'getStats') return {'stats': []};
      return null;
    });
    mock(const MethodChannel('viewvee/audio_monitor'), (_) async => null);
    signaling = _Signaling();
    monitor = AudioMonitorService(
      turnCredentials: TurnCredentialsService(
        getAccessToken: ({bool forceRefresh = false}) async => null,
      ),
      isPremium: true,
      signaling: signaling,
    );
  });

  tearDown(() async {
    await monitor.stop();
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> connected(WidgetTester tester) async {
    messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEventconnection$connectionCount',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'peerConnectionState',
        'state': 'connected',
      }),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('retries the existing pairing and stops timers on recovery', (
    tester,
  ) async {
    await monitor.joinAsReceiver('saved-pairing');
    signaling.onRemoteHangup!();
    expect(monitor.isAutoReconnecting, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(signaling.joins, ['saved-pairing', 'saved-pairing']);
    expect(connectionCount, 2);
    await connected(tester);
    expect(monitor.state, AudioConnectionState.connected);
    expect(monitor.isAutoReconnecting, isFalse);
    await tester.pump(const Duration(seconds: 50));
    expect(signaling.joins, hasLength(2));
    await monitor.stop();
  });

  testWidgets(
    'disabling cancels retries; enabling resumes without pairing again',
    (tester) async {
      await monitor.joinAsReceiver('saved-pairing');
      signaling.onRemoteHangup!();
      monitor.setAutoReconnectEnabled(false);
      expect(monitor.isAutoReconnecting, isFalse);
      await tester.pump(const Duration(seconds: 50));
      expect(signaling.joins, hasLength(1));
      monitor.setAutoReconnectEnabled(true);
      await tester.pump(const Duration(seconds: 3));
      expect(signaling.joins, hasLength(2));
      await monitor.stop();
    },
  );

  testWidgets(
    'stalled media negotiation keeps retrying until explicitly stopped',
    (tester) async {
      await monitor.joinAsReceiver('saved-pairing');
      signaling.onRemoteHangup!();
      for (var attempt = 0; attempt < 7; attempt++) {
        await tester.pump(const Duration(seconds: 3));
        expect(signaling.joins, hasLength(attempt + 2));
        await tester.pump(const Duration(seconds: 40));
      }
      expect(monitor.state, AudioConnectionState.disconnected);
      expect(monitor.isAutoReconnecting, isTrue);
      await monitor.stop();
    },
  );

  testWidgets('a recovered original connection cancels a pending retry', (
    tester,
  ) async {
    await monitor.joinAsReceiver('saved-pairing');
    signaling.onRemoteHangup!();
    await connected(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(signaling.joins, hasLength(1));
    await monitor.stop();
  });

  testWidgets('manual reconnect works with automatic reconnect disabled', (
    tester,
  ) async {
    monitor.setAutoReconnectEnabled(false);
    await monitor.joinAsReceiver('saved-pairing');
    signaling.onRemoteHangup!();
    expect(await monitor.reconnect(), isTrue);
    expect(signaling.joins, ['saved-pairing', 'saved-pairing']);
    expect(monitor.isAutoReconnecting, isFalse);
    await monitor.stop();
    expect(await monitor.reconnect(), isFalse);
  });

  testWidgets('leaving the session cancels pending retries', (tester) async {
    await monitor.joinAsReceiver('saved-pairing');
    signaling.onRemoteHangup!();
    await monitor.stop();
    await tester.pump(const Duration(seconds: 50));
    expect(signaling.joins, hasLength(1));
    expect(monitor.state, AudioConnectionState.idle);
  });

  testWidgets('a join completing after stop cannot restore the session', (
    tester,
  ) async {
    await monitor.joinAsReceiver('saved-pairing');
    signaling.nextJoin = Completer<bool>();
    signaling.onRemoteHangup!();
    await tester.pump(const Duration(seconds: 3));
    await monitor.stop();
    signaling.nextJoin!.complete(true);
    await tester.pump();
    expect(connectionCount, 1);
    expect(monitor.state, AudioConnectionState.idle);
    expect(monitor.isAutoReconnecting, isFalse);
  });
}

class _Signaling extends AudioSignaling {
  final joins = <String>[];
  Completer<bool>? nextJoin;
  @override
  Future<bool> joinRoom(String pairingValue) async {
    joins.add(pairingValue);
    return nextJoin == null ? true : await nextJoin!.future;
  }

  @override
  Future<void> hangUp() async {}
  @override
  Future<void> sendControl(Map<String, dynamic> message) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
