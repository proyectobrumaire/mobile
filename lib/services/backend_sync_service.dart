import 'dart:io';
import 'backend_service.dart';
import 'error_messages.dart';
import 'local_storage_service.dart';
import 'log_parser.dart';
import '../models/sync_progress.dart';

class BackendSyncService {
  final BackendService backend;
  final LocalStorageService storage;

  BackendSyncService(this.backend, this.storage);

  Stream<SyncProgress> sync({bool Function()? isCancelled}) async* {
    final cancelRequested = isCancelled ?? () => false;
    int errors = 0;
    int uploadedPhotos = 0;
    int uploadedLines = 0;
    bool cancelled = false;

    // Fotos marcadas como subidas por versiones anteriores de la app: ya están
    // en la nube, se liberan del teléfono.
    final legacy = await storage.uploadedPhotos();
    await storage.deletePhotos(legacy);

    // ── Log (primero) ──
    // Un solo JSON liviano: así las lecturas y eventos llegan aunque fallen
    // fotos o se cancele a mitad. Si falla, las fotos se suben igual.
    if (cancelRequested()) {
      cancelled = true;
      yield const SyncProgress(SyncStep.subirLog, StepStatus.omitido,
          'No se subieron porque cancelaste; quedan pendientes.');
    } else {
      final entries = await storage.pendingLogEntries();
      if (entries.isEmpty) {
        yield const SyncProgress(SyncStep.subirLog, StepStatus.ok,
            'No hay lecturas pendientes.');
      } else {
        yield SyncProgress(SyncStep.subirLog, StepStatus.enCurso,
            'Subiendo ${plural(entries.length, 'lectura', 'lecturas')}…');
        try {
          await backend.uploadLogs(entries.map((e) => e.entry).toList());
          await storage.markLogEntriesUploaded(entries.map((e) => e.id).toList());
          uploadedLines = entries.length;
          yield SyncProgress(SyncStep.subirLog, StepStatus.ok,
              '${plural(uploadedLines, 'lectura subida', 'lecturas subidas')}. Se borran del '
              'teléfono al terminar, salvo las de fotos aún pendientes.');
        } catch (e) {
          errors++;
          yield SyncProgress(
            SyncStep.subirLog,
            StepStatus.error,
            'No se pudieron subir las lecturas. ${ErrorMessages.backend(e)} '
            'Las fotos se suben igual; las lecturas quedan pendientes para la próxima vez.',
            technical: '$e',
          );
        }
      }
    }

    // ── Fotos (después del log) ──
    // Cada foto se borra del teléfono (archivo y fila) apenas S3 confirma la
    // subida. Sus lecturas se borran al final, cuando también estén subidas.
    final photos = cancelled ? const <StoredPhoto>[] : await storage.pendingPhotos();
    if (cancelled) {
      yield const SyncProgress(SyncStep.subirFotos, StepStatus.omitido,
          'No se subieron porque cancelaste; quedan pendientes.');
    } else if (photos.isEmpty) {
      yield const SyncProgress(SyncStep.subirFotos, StepStatus.ok,
          'No hay fotos pendientes.');
    } else {
      int attempted = 0;
      for (final photo in photos) {
        if (cancelRequested()) {
          cancelled = true;
          break;
        }
        yield SyncProgress(
          SyncStep.subirFotos,
          StepStatus.enCurso,
          'Subiendo foto ${attempted + 1} de ${photos.length}…',
          current: attempted,
          total: photos.length,
        );
        try {
          final bytes = await File(photo.localPath).readAsBytes();
          final ts = _parseTs(photo.timestamp) ?? DateTime.now();
          await backend.uploadPhoto(bytes, photo.filename, ts);
          uploadedPhotos++;
          attempted++;
          try {
            await storage.deletePhotos([photo]);
          } catch (_) {
            // Si no se pudo borrar, al menos queda marcada para no resubirla.
            try {
              await storage.markPhotosUploaded([photo.id]);
            } catch (_) {}
          }
        } catch (e) {
          errors++;
          attempted++;
          yield SyncProgress(
            SyncStep.subirFotos,
            StepStatus.enCurso,
            'Subiendo foto $attempted de ${photos.length}…',
            current: attempted,
            total: photos.length,
            issue: SyncIssue('${photo.filename}: ${ErrorMessages.backend(e)}',
                technical: '$e'),
          );
        }
      }
      final failedCount = attempted - uploadedPhotos;
      yield SyncProgress(
        SyncStep.subirFotos,
        cancelled || failedCount > 0 ? StepStatus.advertencia : StepStatus.ok,
        cancelled
            ? 'Cancelada por ti: $uploadedPhotos de ${photos.length} fotos subidas.'
            : failedCount == 0
                ? '${plural(uploadedPhotos, 'foto subida', 'fotos subidas')} y borradas del teléfono.'
                : '$uploadedPhotos de ${photos.length} fotos subidas; '
                    '${plural(failedCount, 'falló', 'fallaron')} (quedan pendientes).',
        current: attempted,
        total: photos.length,
      );
    }

    // Lecturas ya subidas: se borran del teléfono salvo las de fotos que
    // siguen pendientes (se borrarán cuando esas fotos se suban o se borren).
    try {
      await storage.purgeUploadedLogEntries();
    } catch (_) {
      // No es crítico: se reintenta en la próxima subida.
    }

    yield SyncProgress.done(SyncSummary(
      kind: SyncKind.subida,
      uploadedPhotos: uploadedPhotos,
      uploadedLines: uploadedLines,
      purgedPhotos: legacy.length,
      errors: errors,
      cancelled: cancelled,
    ));
  }

  DateTime? _parseTs(String? ts) => ts == null ? null : LogParser.parseTimestamp(ts);
}
