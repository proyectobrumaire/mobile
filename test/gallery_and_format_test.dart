import 'dart:async';

import 'package:brumaire_mobile/models/fechas.dart';
import 'package:brumaire_mobile/models/gallery_group.dart';
import 'package:brumaire_mobile/models/log_entry.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/services/error_messages.dart';
import 'package:brumaire_mobile/services/local_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

StoredPhoto photo(int id, String ts, int n, {bool uploaded = false}) => StoredPhoto(
      id: id,
      filename: 'image_${ts}_$n.jpg',
      localPath: '/x/image_${ts}_$n.jpg',
      timestamp: ts,
      uploaded: uploaded,
    );

LogEntry sensor(DateTime t, String key, double? v) => LogEntry(
      timestamp: t,
      timestampValid: true,
      type: EntryType.sensorData,
      sensorKey: key,
      sensorValue: v,
      rawLine: '',
    );

void main() {
  group('buildGalleryDays', () {
    test('agrupa por día y evento, lo más reciente primero, con sensores', () {
      final photos = [
        photo(1, '26-05-06T10-00-00', 0),
        photo(2, '26-05-07T08-00-00', 1),
        photo(3, '26-05-07T08-00-00', 0),
        photo(4, '26-05-07T09-15-30', 0),
        const StoredPhoto(id: 5, filename: 'raro.jpg', localPath: '/x/raro.jpg'),
      ];
      final t = DateTime(2026, 5, 7, 8);
      final entries = [
        LogEntry(timestamp: t, timestampValid: true, type: EntryType.event, event: 'BIRD', rawLine: ''),
        sensor(t, 'T1_K', 24.5),
        sensor(t, 'W1_K', null),
        // Mismo instante pero timestamp inválido: no debe cruzarse.
        LogEntry(timestamp: t, timestampValid: false, type: EntryType.sensorData,
            sensorKey: 'H1_K', sensorValue: 1, rawLine: ''),
      ];

      final days = buildGalleryDays(photos, entries);
      expect(days.map((d) => d.date), [DateTime(2026, 5, 7), DateTime(2026, 5, 6), null]);

      final may7 = days.first;
      expect(may7.photoCount, 3);
      expect(may7.groups.map((g) => g.timestamp),
          [DateTime(2026, 5, 7, 9, 15, 30), DateTime(2026, 5, 7, 8)]);

      final bird = may7.groups[1];
      expect(bird.eventType, 'BIRD');
      expect(bird.photos.map((p) => p.id), [3, 2]); // ordenadas por nombre (_0, _1)
      expect(bird.sensors.keys, unorderedEquals(['T1_K', 'W1_K']));
      expect(bird.sensors['W1_K']!.isNaN, isTrue);

      expect(days.last.groups.single.photos.single.id, 5);
    });

    test('sin fotos → lista vacía', () {
      expect(buildGalleryDays([], []), isEmpty);
    });
  });

  group('sensores', () {
    test('formatSensorValue con unidades', () {
      expect(formatSensorValue('T1_K', 24.46), '24.5 °C');
      expect(formatSensorValue('H1_K', 60), '60.0 %');
      expect(formatSensorValue('I4_K', 1.234), '1.23 A');
      expect(formatSensorValue('W1_K', 152.7), '153 g');
      expect(formatSensorValue('P2_K', 255), '255 / 255 (100 %)');
      expect(formatSensorValue('T3_K', double.nan), 'sin lectura');
      expect(formatSensorValue('T3_K', null), 'sin lectura');
      expect(formatSensorValue('Z0_K', 3), '3.0');
    });

    test('orderedSensorKeys respeta el orden del Arduino', () {
      expect(orderedSensorKeys(['W1_K', 'Z0_K', 'T1_K', 'H1_K']),
          ['T1_K', 'H1_K', 'W1_K', 'Z0_K']);
    });
  });

  group('fechas', () {
    final now = DateTime(2026, 9, 27, 15);
    test('encabezados de día', () {
      expect(formatDayHeader(DateTime(2026, 9, 27, 8), now: now), 'Hoy');
      expect(formatDayHeader(DateTime(2026, 9, 26), now: now), 'Ayer');
      expect(formatDayHeader(DateTime(2026, 9, 24), now: now), 'Jueves 24 de septiembre');
      expect(formatDayHeader(DateTime(2025, 1, 1), now: now), 'Miércoles 1 de enero de 2025');
    });
  });

  group('SyncRunState / SyncSummary', () {
    test('acumula pasos e incidencias; el resumen es legible', () {
      final s = SyncRunState(SyncKind.descarga)
        ..apply(const SyncProgress(SyncStep.conectar, StepStatus.enCurso, 'a'))
        ..apply(const SyncProgress(SyncStep.conectar, StepStatus.ok, 'b'))
        ..apply(const SyncProgress(SyncStep.fotos, StepStatus.enCurso, 'c',
            current: 1, total: 4, issue: SyncIssue('x')))
        ..apply(const SyncProgress(SyncStep.fotos, StepStatus.ok, 'd', current: 4, total: 4))
        ..apply(SyncProgress.done(const SyncSummary(
            kind: SyncKind.descarga, newPhotos: 12, newLines: 240, errors: 1)));
      expect(s.steps.map((x) => x.step), [SyncStep.conectar, SyncStep.fotos]);
      expect(s.steps.last.issues.length, 1);
      expect(s.steps.last.fraction, 1.0);
      expect(s.summary!.text, '12 fotos nuevas, 240 lecturas, 1 error');
    });

    test('resumen de subida y de cancelación', () {
      expect(
        const SyncSummary(kind: SyncKind.subida, uploadedPhotos: 1, uploadedLines: 3).text,
        '1 foto subida, 3 lecturas subidas, sin errores',
      );
      const c = SyncSummary(kind: SyncKind.descarga, newPhotos: 3, cancelled: true, logSkipped: true);
      expect(c.title, 'Descarga cancelada');
      expect(c.text, 'Alcanzó a hacer: 3 fotos nuevas, log no procesado, sin errores');
    });
  });

  group('ErrorMessages', () {
    test('traduce errores comunes', () {
      expect(ErrorMessages.esp32(TimeoutException('x')), contains('no respondió'));
      expect(ErrorMessages.esp32(Exception('GET /download falló: 404')), contains('ya no está'));
      expect(ErrorMessages.backend(Exception('Presigner falló: 403')), contains('clave'));
      expect(ErrorMessages.backend(Exception('Upload foto a S3 falló: 403')), contains('S3'));
      expect(ErrorMessages.backend(Exception('ClientException: Failed host lookup')),
          contains('internet'));
    });
  });
}
