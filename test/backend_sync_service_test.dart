import 'dart:io';
import 'dart:typed_data';

import 'package:brumaire_mobile/models/log_entry.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/services/backend_service.dart';
import 'package:brumaire_mobile/services/backend_sync_service.dart';
import 'package:brumaire_mobile/services/local_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Registro compartido del orden de las operaciones.
final calls = <String>[];

class FakeBackend extends BackendService {
  bool failLogs = false;
  Set<String> failPhotos = {};
  FakeBackend() : super('https://x', 'k');

  @override
  Future<void> uploadLogs(List<LogEntry> entries) async {
    calls.add('logs');
    if (failLogs) throw Exception('Presigner falló: 500');
  }

  @override
  Future<void> uploadPhoto(Uint8List bytes, String filename, DateTime timestamp) async {
    calls.add('photo:$filename');
    if (failPhotos.contains(filename)) throw Exception('Upload foto a S3 falló: 403');
  }
}

class FakeStorage implements LocalStorageService {
  final List<StoredPhoto> photos;
  final List<LogEntry> entries;
  final deleted = <int>[];
  List<int>? markedLines;
  FakeStorage(this.photos, this.entries);

  @override
  Future<List<StoredPhoto>> uploadedPhotos() async => [];

  @override
  Future<void> deletePhotos(List<StoredPhoto> list) async {
    if (list.isNotEmpty) calls.add('delete');
    deleted.addAll(list.map((p) => p.id));
  }

  @override
  Future<List<StoredPhoto>> pendingPhotos() async =>
      photos.where((p) => !deleted.contains(p.id)).toList();

  @override
  Future<List<({int id, LogEntry entry})>> pendingLogEntries() async =>
      [for (var i = 0; i < entries.length; i++) (id: 100 + i, entry: entries[i])];

  @override
  Future<void> markLogEntriesUploaded(List<int> ids) async {
    calls.add('mark');
    markedLines = ids;
  }

  @override
  Future<int> purgeUploadedLogEntries() async {
    calls.add('purge');
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late List<StoredPhoto> photos;
  final entries = [
    LogEntry(timestamp: DateTime(2026, 9, 30, 8), timestampValid: true,
        type: EntryType.event, seq: 1, event: 'PERIODIC', rawLine: ''),
    LogEntry(timestamp: DateTime(2026, 9, 30, 8), timestampValid: true,
        type: EntryType.sensorData, seq: 2, sensorKey: 'L1_K', sensorValue: 1, rawLine: ''),
  ];

  setUp(() {
    calls.clear();
    dir = Directory.systemTemp.createTempSync('brumaire_test');
    photos = [
      for (var i = 0; i < 3; i++)
        StoredPhoto(
          id: i + 1,
          filename: 'image_26-09-30T08-00-00_$i.jpg',
          localPath: (File('${dir.path}/f$i.jpg')..writeAsBytesSync([1, 2, 3])).path,
          timestamp: '26-09-30T08-00-00',
        ),
    ];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<SyncRunState> run(FakeBackend b, FakeStorage s, {bool Function()? isCancelled}) async {
    final state = SyncRunState(SyncKind.subida);
    await for (final p in BackendSyncService(b, s).sync(isCancelled: isCancelled)) {
      state.apply(p);
    }
    return state;
  }

  test('orden: log → fotos → purga', () async {
    final storage = FakeStorage(photos, entries);
    final s = await run(FakeBackend(), storage);
    expect(calls.first, 'logs');
    expect(calls[1], 'mark');
    expect(calls.indexOf('photo:${photos.first.filename}'), greaterThan(calls.indexOf('mark')));
    expect(calls.last, 'purge');
    expect(storage.deleted, [1, 2, 3]);
    expect(s.steps.map((x) => x.step), [SyncStep.subirLog, SyncStep.subirFotos]);
    expect(s.summary!.text, '2 lecturas subidas, 3 fotos subidas, sin errores');
  });

  test('si falla el log, las fotos se suben igual (y la purga corre)', () async {
    final storage = FakeStorage(photos, entries);
    final s = await run(FakeBackend()..failLogs = true, storage);
    expect(storage.markedLines, isNull);
    expect(storage.deleted, [1, 2, 3]);
    expect(calls.last, 'purge');
    final log = s.steps.firstWhere((x) => x.step == SyncStep.subirLog);
    expect(log.status, StepStatus.error);
    expect(log.message, contains('Las fotos se suben igual'));
    expect(s.summary!.errors, 1);
    expect(s.summary!.uploadedPhotos, 3);
    expect(s.summary!.uploadedLines, 0);
  });

  test('si fallan fotos, el log ya quedó subido', () async {
    final storage = FakeStorage(photos, entries);
    final s = await run(FakeBackend()..failPhotos = {photos[1].filename}, storage);
    expect(storage.markedLines, [100, 101]);
    expect(storage.deleted, [1, 3]);
    expect(s.summary!.uploadedLines, 2);
    expect(s.summary!.errors, 1);
  });

  test('cancelar durante las fotos: el log ya quedó subido', () async {
    final storage = FakeStorage(photos, entries);
    final s = await run(FakeBackend(), storage,
        isCancelled: () => calls.any((c) => c.startsWith('photo:')));
    expect(storage.markedLines, [100, 101]);
    expect(storage.deleted, [1]);
    expect(calls.last, 'purge');
    expect(s.summary!.cancelled, isTrue);
    expect(s.summary!.title, 'Subida cancelada');
    expect(s.summary!.text, 'Alcanzó a hacer: 2 lecturas subidas, 1 foto subida, sin errores');
  });

  test('cancelar antes de empezar: no sube nada', () async {
    final storage = FakeStorage(photos, entries);
    final s = await run(FakeBackend(), storage, isCancelled: () => true);
    expect(calls, ['purge']);
    expect(s.summary!.cancelled, isTrue);
  });
}
