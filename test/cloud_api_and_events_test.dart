import 'dart:convert';
import 'dart:typed_data';

import 'package:brumaire_mobile/models/event_record.dart';
import 'package:brumaire_mobile/models/log_entry.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/services/backend_service.dart';
import 'package:brumaire_mobile/services/backend_sync_service.dart';
import 'package:brumaire_mobile/services/cloud_gallery_service.dart';
import 'package:brumaire_mobile/services/error_messages.dart';
import 'package:brumaire_mobile/services/local_storage_service.dart';
import 'package:brumaire_mobile/widgets/event_timeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Ejemplos del contrato (.claude/contracts/api-fotos-eventos.md).
const photosExample = '''
{
  "photos": [
    {
      "filename": "image_26-09-24T21-36-19_0.jpg",
      "timestamp": "2026-09-25T02:36:19+00:00",
      "image_url": "https://s3/pred.png",
      "raw_url": "https://s3/raw.jpg",
      "detections": [
        { "species": "colibri_delphinae", "confidence": 0.93, "detector_score": 0.98 },
        { "species": "amazilia_tzacatl", "confidence": 0.95, "detector_score": 0.90 }
      ],
      "env": { "T1_K": 24.5, "H1_K": 70.1 }
    },
    {
      "filename": "image_26-09-24T21-30-00_1.jpg",
      "timestamp": "2026-09-25T02:30:00+00:00",
      "image_url": null,
      "raw_url": "https://s3/raw2.jpg",
      "detections": [],
      "env": {}
    }
  ],
  "truncated": true
}''';

const eventsExample = '''
{
  "events": [
    { "timestamp": "2026-09-25T02:40:00+00:00", "event": "PERIODIC", "env": { "T1_K": 24.5 } },
    { "timestamp": "2026-09-25T01:00:00+00:00", "event": "INVALID_EV", "env": {} }
  ],
  "truncated": false
}''';

void main() {
  group('API de consulta (contrato v1)', () {
    late List<http.Request> requests;

    CloudGalleryService serviceReturning(int status, String body) {
      requests = [];
      return CloudGalleryService(
        'https://api.example.com/',
        'secreto',
        client: MockClient((req) async {
          requests.add(req);
          return http.Response(body, status, headers: {'content-type': 'application/json'});
        }),
      );
    }

    final from = DateTime.utc(2026, 9, 24);
    final to = DateTime.utc(2026, 9, 25);

    test('POST /photos: request y parseo', () async {
      final page = await serviceReturning(200, photosExample).fetchPhotos(from: from, to: to);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://api.example.com/photos');
      expect(req.headers['x-api-key'], 'secreto');
      expect(jsonDecode(req.body), {
        'from': '2026-09-24T00:00:00.000Z',
        'to': '2026-09-25T00:00:00.000Z',
      });

      expect(page.truncated, isTrue);
      expect(page.items.length, 2);
      final a = page.items[0];
      expect(a.timestamp, DateTime.utc(2026, 9, 25, 2, 36, 19));
      expect(a.displayUrl, 'https://s3/pred.png');
      expect(a.detections.length, 2);
      expect(a.species, 'amazilia_tzacatl'); // la de mayor confianza
      expect(a.env, {'T1_K': 24.5, 'H1_K': 70.1});
      final b = page.items[1];
      expect(b.displayUrl, 'https://s3/raw2.jpg'); // sin anotada → original
      expect(b.detections, isEmpty);
      expect(b.species, isNull);
    });

    test('POST /events: request con types y parseo', () async {
      final page = await serviceReturning(200, eventsExample)
          .fetchEvents(from: from, to: to, types: ['PERIODIC', 'VOLCADO']);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(requests.single.url.path, '/events');
      expect(body['types'], ['PERIODIC', 'VOLCADO']);
      expect(page.truncated, isFalse);
      expect(page.items.map((e) => e.event), ['PERIODIC', 'INVALID_EV']);
      expect(page.items.first.env, {'T1_K': 24.5});
      expect(page.items.first.timestamp.isUtc, isTrue);
    });

    test('POST /events sin types no envía la clave', () async {
      await serviceReturning(200, eventsExample).fetchEvents(from: from, to: to);
      expect((jsonDecode(requests.single.body) as Map).containsKey('types'), isFalse);
    });

    test('403 → CloudApiException con mensaje simple', () async {
      final s = serviceReturning(403, '{"error": "Forbidden"}');
      Object? error;
      try {
        await s.fetchPhotos(from: from, to: to);
      } catch (e) {
        error = e;
      }
      expect(error, isA<CloudApiException>());
      expect('$error', 'POST /photos falló: 403 (Forbidden)');
      expect(ErrorMessages.cloud(error!), contains('clave'));
      expect(ErrorMessages.cloud(const CloudApiException('/events', 404)),
          contains('desplegar'));
    });

    test('POST /gallery sigue con el mismo formato y alimenta la fuente Aves', () async {
      final s = serviceReturning(200, jsonEncode({
        'colibri_delphinae': [
          {
            'filename': 'f.jpg',
            'species': 'colibri_delphinae',
            'confidence': 0.9,
            'detector_score': 0.8,
            'timestamp': '2026-09-25T02:36:19+00:00',
            'image_url': 'https://s3/p.png',
            'env': {'T1_K': 20},
          }
        ],
      }));
      final page = await BirdDetectionsSource(s).fetch(from: from, to: to);
      expect(requests.single.url.path, '/gallery');
      expect(page.items.single.species, 'colibri_delphinae');
      expect(page.items.single.env, {'T1_K': 20.0});
    });

    test('fuentes: "Todas" (POST /photos) es la opción por defecto', () {
      final sources = cloudGallerySources('https://x', 'k');
      expect(sources.map((s) => s.label), ['Todas', 'Aves']);
      expect(sources.first, isA<AllPhotosSource>());
      expect(sources.first.grouping, CloudGrouping.porDia);
    });
  });

  group('eventos', () {
    final t1 = DateTime(2026, 9, 27, 8);
    final t2 = DateTime(2026, 9, 26, 23, 55);

    LogEntry ev(DateTime t, String name, {bool valid = true}) => LogEntry(
        timestamp: t, timestampValid: valid, type: EntryType.event, event: name, rawLine: '');
    LogEntry se(DateTime t, String k, double v) => LogEntry(
        timestamp: t, timestampValid: true, type: EntryType.sensorData,
        sensorKey: k, sensorValue: v, rawLine: '');

    test('eventsFromLogEntries: incluye BIRD y cruza sensores por timestamp exacto', () {
      final records = eventsFromLogEntries([
        ev(t1, 'PERIODIC'), se(t1, 'T1_K', 24.5), se(t1, 'H1_K', 60),
        ev(t2, 'BIRD'), se(t2, 'T1_K', 20),
        ev(t2, 'VOLCADO'),
        ev(DateTime(2026, 9, 27, 9), 'INVALID_EV', valid: false),
      ]);
      expect(records.map((r) => r.event), ['PERIODIC', 'BIRD', 'VOLCADO', 'INVALID_EV']);
      expect(records[0].sensors, {'T1_K': 24.5, 'H1_K': 60});
      expect(records[1].sensors, {'T1_K': 20});
      expect(records[1].label, 'Ave detectada');
      expect(records[2].sensors, {'T1_K': 20});
      expect(records[3].sensors, isEmpty);
      expect(records[3].category, otrosEventos);
    });

    test('groupEventsByDay: filtra por categoría, más reciente primero, inválidos al final', () {
      final records = [
        EventRecord(timestamp: t2, event: 'VOLCADO'),
        EventRecord(timestamp: t1, event: 'PERIODIC'),
        EventRecord(timestamp: t1.add(const Duration(hours: 2)), event: 'BOOT'),
        EventRecord(timestamp: t1, event: 'BIRD'),
        EventRecord(timestamp: t1, event: 'XYZ', timestampValid: false),
      ];
      // Local: todas las categorías, BIRD incluido.
      final all = groupEventsByDay(records, eventCategories.toSet());
      expect(all.map((d) => d.date), [DateTime(2026, 9, 27), DateTime(2026, 9, 26), null]);
      expect(all.first.events.map((e) => e.event), ['BOOT', 'PERIODIC', 'BIRD']);
      // Cloud: sin BIRD.
      final cloud = groupEventsByDay(records, cloudEventCategories.toSet());
      expect(cloud.expand((d) => d.events).any((e) => e.event == 'BIRD'), isFalse);
      expect(groupEventsByDay(records, {'BIRD'}).single.events.single.event, 'BIRD');

      final onlyVolcado = groupEventsByDay(records, {'VOLCADO'});
      expect(onlyVolcado.single.events.single.event, 'VOLCADO');
      expect(groupEventsByDay(records, {}), isEmpty);
      expect(countByCategory(records),
          {'VOLCADO': 1, 'PERIODIC': 1, 'BOOT': 1, 'BIRD': 1, otrosEventos: 1});
      expect(eventCategories.first, 'BIRD');
      expect(categoryLabel('BIRD'), 'Ave');
      expect(cloudEventCategories.contains('BIRD'), isFalse);
    });

    test('cloudTypesFor: nunca pide BIRD (aunque esté elegido); "Otros" → INVALID_EV', () {
      expect(cloudTypesFor(eventCategories.toSet()),
          ['PERIODIC', 'BOOT', 'PELTIER_ON', 'PELTIER_OFF', 'VOLCADO', 'INVALID_EV']);
      expect(cloudTypesFor({otrosEventos, 'VOLCADO'}), ['VOLCADO', 'INVALID_EV']);
    });

    test('nombres legibles y resumen de sensores', () {
      expect(eventLabelFor('PERIODIC'), 'Reporte periódico');
      expect(eventLabelFor('BOOT'), 'Arranque del sistema');
      expect(eventLabelFor('PELTIER_ON'), 'Peltier encendida');
      expect(eventLabelFor('PELTIER_OFF'), 'Peltier apagada');
      expect(eventLabelFor('VOLCADO'), 'Vaciado del plato');
      expect(eventLabelFor('FOO'), 'Evento FOO');
      expect(sensorSummary({'T1_K': 24.5, 'P2_K': 128, 'W1_K': 150}),
          '24.5 °C · PWM 128 · 150 g');
      expect(sensorSummary({'T1_K': 24.5, 'L1_K': 1}), '24.5 °C · Lluvia: Sí');
      expect(sensorSummary({'L1_K': 0}), 'Lluvia: No');
    });
  });

  test('la subida incluye las líneas de evento en el JSON', () async {
    final entries = [
      LogEntry(timestamp: DateTime(2026, 9, 27, 8), timestampValid: true,
          type: EntryType.event, seq: 1, event: 'PERIODIC', rawLine: ''),
      LogEntry(timestamp: DateTime(2026, 9, 27, 8), timestampValid: true,
          type: EntryType.sensorData, seq: 2, sensorKey: 'T1_K', sensorValue: 24.5, rawLine: ''),
    ];
    final storage = _UploadStorage(entries);
    final backend = _FakeBackend();
    final state = SyncRunState(SyncKind.subida);
    await for (final p in BackendSyncService(backend, storage).sync()) {
      state.apply(p);
    }
    expect(backend.uploaded.length, 2);
    final json = backend.uploaded.map((e) => e.toJson()).toList();
    expect(json.first['type'], 'event');
    expect(json.first['event'], 'PERIODIC');
    expect(storage.markedUploaded, [10, 11]);
    expect(storage.purged, isTrue);
    expect(state.summary!.uploadedLines, 2);
  });
}

class _FakeBackend extends BackendService {
  final uploaded = <LogEntry>[];
  _FakeBackend() : super('https://x', 'k');

  @override
  Future<void> uploadLogs(List<LogEntry> entries) async => uploaded.addAll(entries);

  @override
  Future<void> uploadPhoto(Uint8List bytes, String filename, DateTime timestamp) async {}
}

class _UploadStorage implements LocalStorageService {
  final List<LogEntry> entries;
  List<int>? markedUploaded;
  bool purged = false;
  _UploadStorage(this.entries);

  @override
  Future<List<StoredPhoto>> uploadedPhotos() async => [];

  @override
  Future<void> deletePhotos(List<StoredPhoto> photos) async {}

  @override
  Future<List<StoredPhoto>> pendingPhotos() async => [];

  @override
  Future<List<({int id, LogEntry entry})>> pendingLogEntries() async =>
      [for (var i = 0; i < entries.length; i++) (id: 10 + i, entry: entries[i])];

  @override
  Future<void> markLogEntriesUploaded(List<int> ids) async => markedUploaded = ids;

  @override
  Future<int> purgeUploadedLogEntries() async {
    purged = true;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
