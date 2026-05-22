import 'package:shared_preferences/shared_preferences.dart';
import 'esp32_service.dart';
import 'log_parser.dart';
import 'backend_service.dart';
import '../models/sync_progress.dart';

export '../models/sync_progress.dart';

class SyncService {
  final Esp32Service esp32;
  final BackendService backend;

  SyncService(this.esp32, this.backend);

  static const _prefSyncedLines = 'last_synced_lines';

  Stream<SyncProgress> sync() async* {
    final prefs = await SharedPreferences.getInstance();

    yield const SyncProgress('Conectando a esp32cam.local...');
    if (!await esp32.isReachable()) {
      yield const SyncProgress(
        'No se encontró el ESP32. ¿Está el hotspot activo y el ESP32 conectado?',
        isError: true,
      );
      return;
    }
    yield const SyncProgress('ESP32 encontrado.');

    try {
      await esp32.setTime(DateTime.now());
      yield const SyncProgress('Hora sincronizada con el ESP32.');
    } catch (e) {
      yield SyncProgress('Advertencia: no se pudo sincronizar la hora: $e', isWarning: true);
    }

    yield const SyncProgress('Listando archivos en la SD...');
    List<Esp32FileInfo> files;
    try {
      files = await esp32.listFiles();
    } catch (e) {
      yield SyncProgress('Error al listar archivos: $e', isError: true);
      return;
    }

    final photos = files.where((f) => f.name.endsWith('.jpg')).toList();
    final hasLog = files.any((f) => f.name == 'log.txt');
    yield SyncProgress('${photos.length} fotos y ${hasLog ? 1 : 0} log encontrados.');

    // — Fotos —
    int done = 0;
    for (final photo in photos) {
      try {
        yield SyncProgress('Descargando ${photo.name}...');
        final bytes = await esp32.downloadFile(photo.name);

        final ts = _tsFromFilename(photo.name);
        yield SyncProgress('Enviando ${photo.name} al servidor...');
        await backend.uploadPhoto(bytes, photo.name, ts);

        await esp32.deleteFile(photo.name);
        done++;
        yield SyncProgress('✓ ${photo.name} ($done/${photos.length})');
      } catch (e) {
        yield SyncProgress('✗ ${photo.name}: $e', isError: true);
      }
    }

    // — Log —
    if (!hasLog) {
      yield const SyncProgress('No hay log.txt en la SD.');
    } else {
      try {
        yield const SyncProgress('Descargando log.txt...');
        final bytes = await esp32.downloadFile('log.txt');
        final content = String.fromCharCodes(bytes);
        final all = LogParser.parse(content);

        final syncedLines = prefs.getInt(_prefSyncedLines) ?? 0;
        final newEntries = all.skip(syncedLines).toList();

        if (newEntries.isEmpty) {
          yield const SyncProgress('Sin entradas nuevas en el log.');
        } else {
          final invalid = newEntries.where((e) => !e.timestampValid).length;
          if (invalid > 0) {
            yield SyncProgress(
              '⚠ $invalid entradas con timestamp inválido (se usará hora actual).',
              isWarning: true,
            );
          }
          yield SyncProgress('Enviando ${newEntries.length} entradas al servidor...');
          await backend.uploadLogs(newEntries);
          yield SyncProgress('✓ Log: ${newEntries.length} entradas nuevas enviadas.');
          try {
            await esp32.resetLog();
            await prefs.setInt(_prefSyncedLines, 0);
            yield const SyncProgress('Log reseteado en ESP32.');
          } catch (e) {
            await prefs.setInt(_prefSyncedLines, all.length);
            yield SyncProgress('Advertencia: no se pudo resetear el log: $e', isWarning: true);
          }
        }
      } catch (e) {
        yield SyncProgress('Error con log.txt: $e', isError: true);
      }
    }

    yield const SyncProgress('— Sincronización completada —');
  }

  // Extrae timestamp del nombre: image_YY-MM-DDTHH-MM-SS_N.jpg
  DateTime _tsFromFilename(String filename) {
    try {
      final base = filename.replaceAll('.jpg', '');
      final parts = base.split('_');
      if (parts.length >= 2) {
        final tsStr = parts[1];
        final sides = tsStr.split('T');
        if (sides.length == 2) {
          final d = sides[0].split('-');
          final t = sides[1].split('-');
          if (d.length == 3 && t.length == 3) {
            final year = 2000 + int.parse(d[0]);
            final month = int.parse(d[1]);
            final day = int.parse(d[2]);
            final hour = int.parse(t[0]);
            final min = int.parse(t[1]);
            final sec = int.parse(t[2]);
            if (year >= 2020 && year <= 2035 && month >= 1 && month <= 12) {
              return DateTime(year, month, day, hour, min, sec);
            }
          }
        }
      }
    } catch (_) {}
    return DateTime.now();
  }
}
