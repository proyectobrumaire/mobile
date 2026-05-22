import 'package:shared_preferences/shared_preferences.dart';
import 'esp32_service.dart';
import 'local_storage_service.dart';
import 'log_parser.dart';
import '../models/sync_progress.dart';

class Esp32SyncService {
  final Esp32Service esp32;
  final LocalStorageService storage;

  Esp32SyncService(this.esp32, this.storage);

  static const _keyAt     = 'esp32_sync_at';
  static const _keyPhotos = 'esp32_sync_photos';
  static const _keyLines  = 'esp32_sync_lines';

  Stream<SyncProgress> sync() async* {
    final prefs = await SharedPreferences.getInstance();

    yield const SyncProgress('Conectando a esp32cam.local...');
    if (!await esp32.isReachable()) {
      yield const SyncProgress(
        'ESP32 no encontrado. ¿Está conectado a la misma red?',
        isError: true,
      );
      return;
    }

    try {
      await esp32.setTime(DateTime.now());
      yield const SyncProgress('Hora sincronizada.');
    } catch (e) {
      yield SyncProgress('⚠ No se pudo sincronizar la hora: $e', isWarning: true);
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
    final hasLog = files.any((f) => f.name.endsWith('log.txt'));
    yield SyncProgress('${photos.length} fotos y ${hasLog ? 1 : 0} log encontrados.');

    int newPhotos = 0;
    for (final photo in photos) {
      try {
        yield SyncProgress('Descargando ${photo.name}...');
        final bytes = await esp32.downloadFile(photo.name);
        final localPath = await storage.savePhotoFile(photo.name, bytes);
        await storage.insertPhoto(photo.name, localPath, _tsFromFilename(photo.name));
        await esp32.deleteFile(photo.name);
        newPhotos++;
        yield SyncProgress('✓ ${photo.name} ($newPhotos/${photos.length})');
      } catch (e) {
        yield SyncProgress('✗ ${photo.name}: $e', isError: true);
      }
    }

    int newLines = 0;
    if (!hasLog) {
      yield const SyncProgress('Sin log.txt en la SD.');
    } else {
      try {
        yield const SyncProgress('Descargando log.txt...');
        final logFile = files.firstWhere((f) => f.name.endsWith('log.txt'));
        final bytes = await esp32.downloadFile(logFile.name);
        final content = String.fromCharCodes(bytes);
        final all = LogParser.parse(content);

        final maxSeq = await storage.maxStoredSeq();
        final newEntries = all.where((e) => e.seq == null || e.seq! > maxSeq).toList();

        final invalidCount = newEntries.where((e) => !e.timestampValid).length;
        if (invalidCount > 0) {
          yield SyncProgress(
            '⚠ $invalidCount entradas con timestamp inválido (datos guardados igualmente).',
            isWarning: true,
          );
        }

        newLines = await storage.insertLogEntries(newEntries);
        yield SyncProgress('✓ $newLines líneas nuevas guardadas localmente.');

        try {
          await esp32.resetLog();
          yield const SyncProgress('Log reseteado en ESP32.');
        } catch (e) {
          yield SyncProgress('⚠ No se pudo resetear el log: $e', isWarning: true);
        }
      } catch (e) {
        yield SyncProgress('Error con log.txt: $e', isError: true);
      }
    }

    await prefs.setString(_keyAt, DateTime.now().toIso8601String());
    await prefs.setInt(_keyPhotos, newPhotos);
    await prefs.setInt(_keyLines, newLines);

    yield const SyncProgress('— Descarga completada —');
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

  String? _tsFromFilename(String filename) {
    try {
      final parts = filename.replaceAll('.jpg', '').split('_');
      if (parts.length >= 2) return parts[1];
    } catch (_) {}
    return null;
  }
}
