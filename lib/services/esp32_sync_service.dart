import 'package:shared_preferences/shared_preferences.dart';
import 'esp32_service.dart';
import 'error_messages.dart';
import 'local_storage_service.dart';
import 'log_parser.dart';
import '../models/sync_progress.dart';

class Esp32SyncService {
  final Esp32Service esp32;
  final LocalStorageService storage;

  /// Espera entre reintentos (inyectable en tests).
  final Future<void> Function(Duration) _delay;

  Esp32SyncService(this.esp32, this.storage, {Future<void> Function(Duration)? delay})
      : _delay = delay ?? ((d) => Future<void>.delayed(d));

  /// GET /list reintentando si la SD está ocupada ("SD Busy", transitorio).
  Future<Esp32FileList> _listWithRetry() async {
    for (var attempt = 1;; attempt++) {
      try {
        return await esp32.listFilesPage();
      } on Esp32HttpException catch (e) {
        if (!e.isSdBusy || attempt >= 3) rethrow;
        await _delay(const Duration(milliseconds: 1500));
      }
    }
  }

  static const _keyAt     = 'esp32_sync_at';
  static const _keyPhotos = 'esp32_sync_photos';
  static const _keyLines  = 'esp32_sync_lines';
  static const keyContinuous = 'esp32_continuous_download';

  /// Descarga la SD del ESP32.
  ///
  /// - `continuous == false`: procesa solo el lote que devuelve /list (máx. 20).
  /// - `continuous == true`: repite listar → descargar → borrar mientras /list
  ///   devuelva `truncated: true`. Se detiene si un lote no logra sacar ninguna
  ///   foto de la SD (evita un bucle infinito).
  ///
  /// log.txt se descarga directo (no depende de /list) una sola vez al final.
  /// `isCancelled` se consulta entre fotos para poder detener la descarga.
  Stream<SyncProgress> sync({
    bool continuous = false,
    bool Function()? isCancelled,
  }) async* {
    final cancelRequested = isCancelled ?? () => false;
    final prefs = await SharedPreferences.getInstance();
    int errors = 0;
    int warnings = 0;

    // ── Conexión ──
    yield SyncProgress(SyncStep.conectar, StepStatus.enCurso,
        'Buscando el ESP32 en ${esp32.staHost}…');
    final health = await esp32.checkStatus();
    if (health.status == Esp32Status.noEncontrado) {
      yield SyncProgress(
        SyncStep.conectar,
        StepStatus.error,
        'No se encontró el ESP32. Verifica que el teléfono esté en la misma red '
        'que la estación y que esté encendida.',
        technical: health.technical,
      );
      yield SyncProgress.done(
        const SyncSummary(kind: SyncKind.descarga, errors: 1, fatal: true, logSkipped: true),
      );
      return;
    }
    if (health.status == Esp32Status.modoAp) {
      yield SyncProgress(
        SyncStep.conectar,
        StepStatus.error,
        'El ESP32 está en modo configuración (sin WiFi): configura su red antes de descargar.',
        technical: health.technical,
      );
      yield SyncProgress.done(
        const SyncSummary(kind: SyncKind.descarga, errors: 1, fatal: true, logSkipped: true),
      );
      return;
    }
    yield SyncProgress(SyncStep.conectar, StepStatus.ok, 'Conectado a ${esp32.staHost}.');
    if (health.status == Esp32Status.sdNoResponde) {
      // El ESP32 responde pero la SD no: no hay nada que descargar y el log
      // tampoco se puede leer.
      yield SyncProgress(
        SyncStep.listar,
        StepStatus.error,
        ErrorMessages.esp32(const Esp32HttpException('GET /list', 500, 'Failed to open Dir')),
        technical: health.technical,
      );
      yield const SyncProgress(SyncStep.log, StepStatus.omitido,
          'No se procesó porque la SD no responde.');
      yield SyncProgress.done(
        const SyncSummary(kind: SyncKind.descarga, errors: 1, fatal: true, logSkipped: true),
      );
      return;
    }

    // ── Hora ──
    yield const SyncProgress(SyncStep.hora, StepStatus.enCurso,
        'Enviando la hora del teléfono a la estación…');
    try {
      await esp32.setTime(DateTime.now());
      yield const SyncProgress(SyncStep.hora, StepStatus.ok,
          'La estación quedó con la hora del teléfono.');
    } catch (e) {
      warnings++;
      yield SyncProgress(
        SyncStep.hora,
        StepStatus.advertencia,
        'No se pudo ajustar la hora de la estación. Las fotos se descargan igual.',
        technical: '$e',
      );
    }

    // ── Fotos, por lotes ──
    // No se conoce el total de la SD (/list da máx. 20 y `truncated`): la barra
    // determinada es solo del lote actual; el acumulado va como contador.
    int batch = 0;
    int newPhotos = 0;
    int repeatedPhotos = 0;
    int totalSeen = 0;     // fotos listadas en todos los lotes
    final failed = <String>{};
    bool sdHasMore = false;
    bool stoppedNoProgress = false;
    bool listFailed = false;
    bool sdFailed = false;
    bool cancelled = false;

    String overallText(bool more) {
      final done = plural(newPhotos + repeatedPhotos, 'foto descargada', 'fotos descargadas');
      return more ? '$done, quedan más en la SD' : done;
    }

    while (true) {
      if (cancelRequested()) {
        cancelled = true;
        break;
      }
      batch++;
      final prefix = continuous ? 'Lote $batch: ' : '';
      yield SyncProgress(SyncStep.listar, StepStatus.enCurso,
          '${prefix}leyendo la lista de archivos…');

      Esp32FileList page;
      try {
        page = await _listWithRetry();
      } catch (e) {
        errors++;
        listFailed = true;
        if (e is Esp32HttpException && e.isSdFailure) sdFailed = true;
        yield SyncProgress(
          SyncStep.listar,
          StepStatus.error,
          sdFailed
              ? ErrorMessages.esp32(e)
              : 'No se pudo leer la lista de archivos. ${ErrorMessages.esp32(e)}',
          technical: '$e',
        );
        break;
      }
      sdHasMore = page.truncated;

      // Las fotos que ya fallaron en esta corrida no se reintentan.
      final photos = page.files
          .where((f) => f.name.toLowerCase().endsWith('.jpg'))
          .where((f) => !failed.contains(f.name))
          .toList();
      totalSeen += photos.length;

      yield SyncProgress(
        SyncStep.listar,
        StepStatus.ok,
        '$prefix${plural(photos.length, 'foto', 'fotos')} en este lote'
        '${page.truncated ? ' (la SD tiene más archivos de los que caben en un lote)' : ''}.',
      );

      if (photos.isEmpty) {
        if (continuous && page.truncated) stoppedNoProgress = true;
        break;
      }

      final keepGoing = continuous && page.truncated;
      int okInBatch = 0;
      int doneInBatch = 0;
      for (final photo in photos) {
        // Cancelación cooperativa: solo entre fotos, nunca a mitad de
        // descargar → guardar → registrar → borrar.
        if (cancelRequested()) {
          cancelled = true;
          break;
        }
        yield SyncProgress(
          SyncStep.fotos,
          StepStatus.enCurso,
          '${continuous ? 'Lote $batch: ' : ''}foto ${doneInBatch + 1} de ${photos.length}',
          current: doneInBatch,
          total: photos.length,
          overall: overallText(page.truncated),
          overallOngoing: keepGoing,
        );
        SyncIssue? issue;
        try {
          final isNew = await _downloadOne(photo.name);
          okInBatch++;
          isNew ? newPhotos++ : repeatedPhotos++;
        } catch (e) {
          failed.add(photo.name);
          errors++;
          issue = SyncIssue('${photo.name}: ${ErrorMessages.esp32(e)}', technical: '$e');
        }
        doneInBatch++;
        yield SyncProgress(
          SyncStep.fotos,
          StepStatus.enCurso,
          '${continuous ? 'Lote $batch: ' : ''}foto $doneInBatch de ${photos.length}',
          current: doneInBatch,
          total: photos.length,
          overall: overallText(page.truncated),
          overallOngoing: keepGoing,
          issue: issue,
        );
      }
      if (cancelled) break;
      if (!keepGoing) break;
      if (okInBatch == 0) {
        stoppedNoProgress = true;
        break;
      }
    }

    // Estado final del paso de fotos.
    final repeatedNote = repeatedPhotos > 0
        ? ' ${plural(repeatedPhotos, 'ya estaba', 'ya estaban')} en el teléfono.'
        : '';
    if (stoppedNoProgress) {
      // Si hubo fotos fallidas ya se contaron como errores.
      if (failed.isEmpty) errors++;
      yield SyncProgress(
        SyncStep.fotos,
        StepStatus.error,
        'Descarga continua detenida: en el lote $batch no se pudo sacar ninguna '
        'foto de la SD, así que se detuvo para no repetir lo mismo en bucle.',
        overall: overallText(true),
        technical: failed.isEmpty
            ? 'El lote $batch no traía fotos pero /list devolvió truncated:true '
                '(otros archivos o carpetas ocupan la lista).'
            : '${failed.length} fotos fallaron: ${failed.join(', ')}',
      );
    } else if (cancelled) {
      yield SyncProgress(
        SyncStep.fotos,
        StepStatus.advertencia,
        'Cancelada por ti.$repeatedNote Lo que quedó en la SD se descarga la próxima vez.',
        overall: overallText(false),
      );
    } else if (listFailed && totalSeen == 0) {
      yield const SyncProgress(SyncStep.fotos, StepStatus.omitido,
          'No se descargaron fotos porque no se pudo leer la SD.');
    } else if (totalSeen == 0) {
      yield const SyncProgress(SyncStep.fotos, StepStatus.ok,
          'No hay fotos nuevas en la SD.');
    } else {
      final remaining = !continuous && sdHasMore;
      if (remaining) warnings++;
      final hasIssues = failed.isNotEmpty || listFailed || remaining;
      yield SyncProgress(
        SyncStep.fotos,
        hasIssues ? StepStatus.advertencia : StepStatus.ok,
        [
          if (failed.isNotEmpty)
            '${plural(failed.length, 'foto no se pudo descargar', 'fotos no se pudieron descargar')} '
                '(siguen en la SD).',
          if (repeatedNote.isNotEmpty) repeatedNote.trim(),
          if (remaining)
            'Quedan más archivos en la SD: vuelve a descargar o activa «Descarga continua».',
          if (!hasIssues && repeatedNote.isEmpty) 'Listo.',
        ].join(' '),
        overall: '${overallText(remaining)}.',
      );
    }

    // ── log.txt ──
    // Se pide directo y no se busca en /list: /list devuelve máx. 20 archivos
    // y log.txt puede quedar fuera si hay muchas fotos en la SD.
    int newLines = 0;
    bool logSkipped = false;
    if (cancelled || cancelRequested()) {
      cancelled = true;
      logSkipped = true;
      yield const SyncProgress(SyncStep.log, StepStatus.omitido,
          'No se procesó porque cancelaste; queda en la SD para la próxima vez.');
    } else if (sdFailed) {
      logSkipped = true;
      yield const SyncProgress(SyncStep.log, StepStatus.omitido,
          'No se procesó porque la SD no responde.');
    } else {
      yield const SyncProgress(SyncStep.log, StepStatus.enCurso,
          'Descargando el registro de sensores (log.txt)…');
      try {
        final bytes = await esp32.tryDownloadFile('log.txt');
        if (bytes == null) {
          yield const SyncProgress(SyncStep.log, StepStatus.ok,
              'No hay lecturas nuevas (la SD no tiene log.txt).');
        } else {
          final content = String.fromCharCodes(bytes);
          final all = LogParser.parse(content);
          final maxSeq = await storage.maxStoredSeq();
          final newEntries =
              all.where((e) => e.seq == null || e.seq! > maxSeq).toList();
          final invalidCount = newEntries.where((e) => !e.timestampValid).length;

          newLines = await storage.insertLogEntries(newEntries);

          // /reset_log solo después de guardar en SQLite (en una transacción).
          String? resetError;
          try {
            await esp32.resetLog();
          } catch (e) {
            resetError = '$e';
          }

          final notes = <String>[
            '${plural(newLines, 'lectura nueva guardada', 'lecturas nuevas guardadas')}.',
            if (invalidCount > 0)
              '$invalidCount con fecha inválida (se guardaron igual).',
            if (resetError != null)
              'No se pudo vaciar el log en la estación; no se pierde nada, '
                  'las repetidas se ignoran la próxima vez.',
          ];
          final warn = invalidCount > 0 || resetError != null;
          if (warn) warnings++;
          yield SyncProgress(
            SyncStep.log,
            warn ? StepStatus.advertencia : StepStatus.ok,
            notes.join(' '),
            technical: resetError != null ? 'POST /reset_log → $resetError' : null,
          );
        }
      } catch (e) {
        errors++;
        logSkipped = true;
        yield SyncProgress(
          SyncStep.log,
          StepStatus.error,
          'No se pudo descargar el registro de sensores. ${ErrorMessages.esp32(e)}',
          technical: '$e',
        );
      }
    }

    await prefs.setString(_keyAt, DateTime.now().toIso8601String());
    await prefs.setInt(_keyPhotos, newPhotos);
    await prefs.setInt(_keyLines, newLines);

    yield SyncProgress.done(SyncSummary(
      kind: SyncKind.descarga,
      newPhotos: newPhotos,
      repeatedPhotos: repeatedPhotos,
      newLines: newLines,
      errors: errors,
      warnings: warnings,
      cancelled: cancelled,
      logSkipped: logSkipped,
    ));
  }

  /// Descarga, guarda, registra y borra del ESP32 una foto.
  /// Devuelve false si la foto ya estaba registrada en el teléfono.
  /// savePhotoFile escribe de forma atómica: nunca queda un JPEG a medias.
  Future<bool> _downloadOne(String name) async {
    final bytes = await esp32.downloadFile(name);
    final localPath = await storage.savePhotoFile(name, bytes);
    final isNew =
        await storage.insertPhoto(name, localPath, photoTimestampFromFilename(name));
    // Si /delete falla, la foto queda en la SD y se vuelve a bajar la próxima
    // vez (insertPhoto la ignora por nombre repetido).
    await esp32.deleteFile(name);
    return isNew;
  }

  static Future<({DateTime? at, int photos, int lines})> lastSyncInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyAt);
    return (
      at: raw != null ? DateTime.tryParse(raw) : null,
      photos: prefs.getInt(_keyPhotos) ?? 0,
      lines: prefs.getInt(_keyLines) ?? 0,
    );
  }

  static Future<bool> loadContinuousPref() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyContinuous) ?? false;
  }

  static Future<void> saveContinuousPref(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyContinuous, value);
  }
}

/// image_YY-MM-DDTHH-MM-SS_N.jpg → "YY-MM-DDTHH-MM-SS".
String? photoTimestampFromFilename(String filename) {
  final parts = filename.replaceAll('.jpg', '').split('_');
  return parts.length >= 2 ? parts[1] : null;
}
