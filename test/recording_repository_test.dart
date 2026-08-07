import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewvee/recordings/recording_repository.dart';
import 'package:viewvee/screens/recordings_screen.dart';
import 'package:viewvee/theme/viewvee_theme.dart';

void main() {
  late Directory directory;
  late RecordingRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('viewvee-recordings-');
    repository = RecordingRepository(directoryProvider: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('stores, lists and deletes recording metadata', () async {
    final createdAt = DateTime(2026, 8, 6, 12, 30);
    final path = await repository.createPath(RecordingSource.camera);
    await File(path).writeAsBytes(List<int>.filled(2048, 1));
    await repository.saveMetadata(
      path: path,
      source: RecordingSource.camera,
      createdAt: createdAt,
      duration: const Duration(seconds: 42),
    );

    final recordings = await repository.loadRecordings();

    expect(recordings, hasLength(1));
    expect(recordings.single.source, RecordingSource.camera);
    expect(recordings.single.createdAt, createdAt);
    expect(recordings.single.duration, const Duration(seconds: 42));
    expect(recordings.single.sizeBytes, 2048);

    await repository.delete(recordings.single);
    expect(await repository.loadRecordings(), isEmpty);
  });

  testWidgets('recordings screen shows saved local videos', (tester) async {
    final recordings = await tester.runAsync(() async {
      final path = await repository.createPath(RecordingSource.monitor);
      await File(path).writeAsBytes(List<int>.filled(4096, 1));
      await repository.saveMetadata(
        path: path,
        source: RecordingSource.monitor,
        createdAt: DateTime(2026, 8, 6, 9, 5),
        duration: const Duration(minutes: 1, seconds: 7),
      );
      return repository.loadRecordings();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildViewveeTheme(),
        home: Scaffold(
          body: RecordingsScreen(
            repository: repository,
            initialRecordings: recordings,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('recordingsPage')), findsOneWidget);
    expect(find.text('Monitor'), findsOneWidget);
    expect(find.textContaining('1:07'), findsOneWidget);
    expect(find.text('Uložit nebo sdílet'), findsNothing);
  });
}
