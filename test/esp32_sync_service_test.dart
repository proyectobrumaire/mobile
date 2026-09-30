import 'dart:typed_data';

import 'package:brumaire_mobile/models/log_entry.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/services/esp32_service.dart';
import 'package:brumaire_mobile/services/esp32_sync_service.dart';
import 'package:brumaire_mobile/services/local_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ESP32 simulado: una SD en memoria; /list devuelve máx. 20 archivos.
class FakeEsp32 extends Esp32Service {
  final List<String> sd;
  final Set<String> failDownload;
  final Set<String> failDelete;
  final bool reachable;
  String? log;
  int listCalls = 0;
  int logDownloads = 0;
  int resetCalls = 0;
  int downloads = 0;
  bool failLog = false;

  /// Orden de las llamadas relevantes ("list", "log", "reset", "photo").
  final calls = <String>[];

  FakeEsp32(
    this.sd, {
    this.failDownload = const {},
    this.failDelete = const {},
    this.reachable = true,
    this.log,
  }) : super(staHost: 'fake');

  /// Respuesta simulada de /list cuando falla (null = responde normal).
  Esp32HttpException? listError;
  int listErrorTimes = 1 << 30;

  @override
  Future<Esp32Health> checkStatus({Duration timeout = const Duration(seconds: 10)}) async {
    if (!reachable) return const Esp32Health(Esp32Status.noEncontrado, 'timeout');
    final err = listError;
    if (err != null && listErrorTimes > 0) {
      return Esp32Health(Esp32Service.classifyList(err.statusCode, err.body), '$err');
    }
    return const Esp32Health(Esp32Status.conectado);
  }

  @override
  Future<void> setTime(DateTime dt) async {}

  @override
  Future<Esp32FileList> listFilesPage() async {
    listCalls++;
    calls.add('list');
    if (listCalls > 100) throw StateError('bucle infinito');
    final err = listError;
    if (err != null && listErrorTimes > 0) {
      listErrorTimes--;
      throw err;
    }
    final page = sd.take(20).map((n) => Esp32FileInfo(name: n, size: 1)).toList();
    return Esp32FileList(files: page, count: page.length, truncated: sd.length > 20);
  }

  @override
  Future<Uint8List> downloadFile(String filename) async {
    downloads++;
    calls.add('photo');
    if (failDownload.contains(filename)) throw Exception('GET /download falló: 500');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List?> tryDownloadFile(String filename) async {
    logDownloads++;
    calls.add('log');
    if (failLog) throw Exception('GET /download falló: 500');
    return log == null ? null : Uint8List.fromList(log!.codeUnits);
  }

  @override
  Future<void> deleteFile(String filename) async {
    if (failDelete.contains(filename)) throw Exception('GET /delete falló: 500');
    sd.remove(filename);
  }

  @override
  Future<void> resetLog() async {
    resetCalls++;
    calls.add('reset');
    log = null;
  }
}

/// Almacenamiento en memoria (solo lo que usa Esp32SyncService).
class FakeStorage implements LocalStorageService {
  final photos = <String>{};
  final entries = <LogEntry>[];
  int maxSeq = -1;

  @override
  Future<String> savePhotoFile(String filename, Uint8List bytes) async => '/tmp/$filename';

  @override
  Future<bool> insertPhoto(String filename, String localPath, String? ts) async =>
      photos.add(filename);

  @override
  Future<int> maxStoredSeq() async => maxSeq;

  @override
  Future<int> insertLogEntries(List<LogEntry> list) async {
    entries.addAll(list);
    for (final e in list) {
      if (e.seq != null && e.seq! > maxSeq) maxSeq = e.seq!;
    }
    return list.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> photoNames(int n, {String prefix = '26-05-07T08-00'}) => [
      for (var i = 0; i < n; i++)
        'image_$prefix-${(i ~/ 3).toString().padLeft(2, '0')}_${i % 3}.jpg',
    ];

Future<SyncRunState> run(
  FakeEsp32 esp,
  FakeStorage storage, {
  bool continuous = false,
  bool Function()? isCancelled,
}) async {
  final state = SyncRunState(SyncKind.descarga);
  await for (final p in Esp32SyncService(esp, storage, delay: (_) async {})
      .sync(continuous: continuous, isCancelled: isCancelled)) {
    state.apply(p);
  }
  return state;
}

SyncStepState step(SyncRunState s, SyncStep step) =>
    s.steps.firstWhere((x) => x.step == step);

const logV2 = '26-05-07T08-00-00,1,BIRD,-,0\n'
    '26-05-07T08-00-00,2,-,T1_K,24.500\n'
    '26-05-07T08-00-00,3,-,H1_K,60.000\n';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('un solo lote: descarga máx. 20 y avisa que quedan más', () async {
    final esp = FakeEsp32(photoNames(45), log: logV2);
    final storage = FakeStorage();
    final s = await run(esp, storage);

    expect(storage.photos.length, 20);
    expect(esp.sd.length, 25);
    expect(esp.listCalls, 1);
    expect(s.summary!.newPhotos, 20);
    expect(s.summary!.newLines, 3);
    expect(s.summary!.warnings, greaterThan(0));
    expect(step(s, SyncStep.fotos).message, contains('Descarga continua'));
    expect(esp.logDownloads, 1);
  });

  test('continua: repite mientras truncated y vacía la SD; log una sola vez', () async {
    final esp = FakeEsp32(photoNames(45), log: logV2);
    final storage = FakeStorage();
    final s = await run(esp, storage, continuous: true);

    expect(esp.sd, isEmpty);
    expect(storage.photos.length, 45);
    expect(esp.listCalls, 3);
    expect(esp.logDownloads, 1);
    expect(esp.resetCalls, 1);
    expect(s.summary!.errors, 0);
    expect(s.summary!.text, '45 fotos nuevas, 3 lecturas, sin errores');
    expect(step(s, SyncStep.fotos).status, StepStatus.ok);
  });

  test('continua: si ninguna foto del lote se descarga, se detiene', () async {
    final names = photoNames(45);
    final esp = FakeEsp32(names, failDownload: names.toSet());
    final storage = FakeStorage();
    final s = await run(esp, storage, continuous: true);

    expect(esp.listCalls, 1);
    expect(esp.downloads, 20);
    expect(storage.photos, isEmpty);
    expect(step(s, SyncStep.fotos).status, StepStatus.error);
    expect(step(s, SyncStep.fotos).message, contains('bucle'));
    expect(s.summary!.errors, 20);
  });

  test('continua: fotos que fallan no se reintentan y no bloquean al resto', () async {
    final names = photoNames(45);
    final bad = names.take(5).toSet();
    final esp = FakeEsp32(names, failDownload: bad);
    final storage = FakeStorage();
    final s = await run(esp, storage, continuous: true);

    expect(storage.photos.length, 40);
    expect(esp.sd.toSet(), bad);
    expect(esp.downloads, 45); // cada foto mala se intentó una sola vez
    expect(s.summary!.errors, 5);
    expect(step(s, SyncStep.fotos).issues.length, 5);
  });

  test('continua: si /delete falla siempre, no entra en bucle', () async {
    final names = photoNames(25);
    final esp = FakeEsp32(names, failDelete: names.toSet());
    final storage = FakeStorage();
    final s = await run(esp, storage, continuous: true);

    expect(esp.listCalls, lessThanOrEqualTo(3));
    expect(step(s, SyncStep.fotos).status, StepStatus.error);
  });

  test('cancelar durante las fotos: se detiene entre fotos y el log ya quedó procesado', () async {
    final esp = FakeEsp32(photoNames(45), log: logV2);
    final storage = FakeStorage();
    final s = await run(esp, storage,
        continuous: true, isCancelled: () => storage.photos.length >= 3);

    expect(storage.photos.length, 3);
    expect(esp.sd.length, 42);
    expect(esp.logDownloads, 1);
    expect(esp.resetCalls, 1);
    expect(storage.entries.length, 3);
    expect(s.summary!.cancelled, isTrue);
    expect(s.summary!.logSkipped, isFalse);
    expect(s.summary!.title, 'Descarga cancelada');
    expect(s.summary!.text, 'Alcanzó a hacer: 3 fotos nuevas, 3 lecturas, sin errores');
    expect(step(s, SyncStep.log).status, StepStatus.ok);
  });

  test('cancelar antes de empezar: no procesa log.txt ni /reset_log ni fotos', () async {
    final esp = FakeEsp32(photoNames(5), log: logV2);
    final storage = FakeStorage();
    final s = await run(esp, storage, isCancelled: () => true);
    expect(esp.calls, isEmpty);
    expect(s.summary!.cancelled, isTrue);
    expect(s.summary!.logSkipped, isTrue);
    expect(step(s, SyncStep.log).status, StepStatus.omitido);
  });

  test('orden: log.txt y /reset_log primero, después las fotos (un lote y continuo)', () async {
    for (final continuous in [false, true]) {
      final esp = FakeEsp32(photoNames(25), log: logV2);
      final s = await run(esp, FakeStorage(), continuous: continuous);
      expect(esp.calls.take(3), ['log', 'reset', 'list'], reason: 'continuous=$continuous');
      expect(esp.calls.where((c) => c == 'log').length, 1);
      expect(s.steps.map((x) => x.step).toList().indexOf(SyncStep.log),
          lessThan(s.steps.map((x) => x.step).toList().indexOf(SyncStep.fotos)));
    }
  });

  test('si el log falla, las fotos se descargan igual', () async {
    final esp = FakeEsp32(photoNames(4), log: logV2)..failLog = true;
    final storage = FakeStorage();
    final s = await run(esp, storage);
    expect(storage.photos.length, 4);
    expect(esp.resetCalls, 0);
    expect(step(s, SyncStep.log).status, StepStatus.error);
    expect(step(s, SyncStep.log).message, contains('reintentará'));
    expect(s.summary!.errors, 1);
    expect(s.summary!.newPhotos, 4);
  });

  test('progreso: barra por lote, contador acumulado con "quedan más"', () async {
    final esp = FakeEsp32(photoNames(30));
    final events = <SyncProgress>[];
    await for (final p in Esp32SyncService(esp, FakeStorage()).sync(continuous: true)) {
      events.add(p);
    }
    final photoEvents = events.where((e) => e.step == SyncStep.fotos && e.total != null);
    // El total de la barra nunca supera el tamaño de un lote.
    expect(photoEvents.every((e) => e.total! <= 20), isTrue);
    expect(photoEvents.first.overallOngoing, isTrue);
    expect(photoEvents.first.overall, contains('quedan más'));
  });

  test('ESP32 inalcanzable: error claro y resumen fatal', () async {
    final s = await run(FakeEsp32([], reachable: false), FakeStorage());
    final c = step(s, SyncStep.conectar);
    expect(c.status, StepStatus.error);
    expect(c.message, contains('misma red'));
    expect(c.technical, isNotNull);
    expect(s.summary!.fatal, isTrue);
  });

  test('log: solo importa líneas con seq mayor al máximo ya importado', () async {
    final esp = FakeEsp32([], log: logV2);
    final storage = FakeStorage()..maxSeq = 2;
    final s = await run(esp, storage);
    expect(storage.entries.length, 1);
    expect(s.summary!.newLines, 1);
  });

  test('parseList lee files, count y truncated', () {
    final l = Esp32Service.parseList(
        '{"files":[{"name":"a.jpg","size":10},{"name":"log.txt","size":5}], "count":2, "truncated":true}');
    expect(l.files.map((f) => f.name), ['a.jpg', 'log.txt']);
    expect(l.count, 2);
    expect(l.truncated, isTrue);
    expect(Esp32Service.parseList('{"files":[]}').truncated, isFalse);
  });

  test('photoTimestampFromFilename', () {
    expect(photoTimestampFromFilename('image_26-05-07T08-30-00_2.jpg'), '26-05-07T08-30-00');
  });

  test('SD que no responde al conectar: error claro, sin log ni /reset_log', () async {
    final esp = FakeEsp32(photoNames(5), log: logV2)
      ..listError = const Esp32HttpException('GET /list', 500, 'Failed to open Dir');
    final s = await run(esp, FakeStorage(), continuous: true);
    expect(step(s, SyncStep.conectar).status, StepStatus.ok);
    final l = step(s, SyncStep.listar);
    expect(l.status, StepStatus.error);
    expect(l.message, contains('SD no responde'));
    expect(l.technical, contains('Failed to open Dir'));
    expect(esp.logDownloads, 0);
    expect(esp.resetCalls, 0);
    expect(s.summary!.fatal, isTrue);
  });

  test('SD que deja de responder al listar: error claro; el log ya se procesó antes', () async {
    // checkStatus dice conectado, pero /list falla después.
    final esp2 = _ListFailsEsp(photoNames(5), log: logV2);
    final s2 = await run(esp2, FakeStorage());
    expect(step(s2, SyncStep.listar).message, contains('SD no responde'));
    expect(step(s2, SyncStep.log).status, StepStatus.ok);
    expect(esp2.logDownloads, 1);
  });

  test('SD ocupada: /list se reintenta', () async {
    final esp = _BusyOnceEsp(photoNames(3), log: logV2);
    final storage = FakeStorage();
    final s = await run(esp, storage);
    expect(storage.photos.length, 3);
    expect(s.summary!.errors, 0);
    expect(esp.listCalls, 2);
  });
}

/// checkStatus dice conectado, pero /list responde "Failed to open Dir".
class _ListFailsEsp extends FakeEsp32 {
  _ListFailsEsp(super.sd, {super.log});
  @override
  Future<Esp32FileList> listFilesPage() async {
    listCalls++;
    throw const Esp32HttpException('GET /list', 500, 'Failed to open Dir');
  }
}

/// El primer /list responde "SD Busy (503)".
class _BusyOnceEsp extends FakeEsp32 {
  _BusyOnceEsp(super.sd, {super.log});
  @override
  Future<Esp32FileList> listFilesPage() async {
    if (listCalls == 0) {
      listCalls++;
      throw const Esp32HttpException('GET /list', 500, 'SD Busy (503)');
    }
    return super.listFilesPage();
  }
}
