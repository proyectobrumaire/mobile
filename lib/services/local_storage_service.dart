import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/log_entry.dart';
import 'log_parser.dart';

class StoredPhoto {
  final int id;
  final String filename;
  final String localPath;
  final String? timestamp;
  final bool uploaded;
  const StoredPhoto({
    required this.id,
    required this.filename,
    required this.localPath,
    this.timestamp,
    this.uploaded = false,
  });

  factory StoredPhoto._fromRow(Map<String, Object?> r) => StoredPhoto(
        id: r['id'] as int,
        filename: r['filename'] as String,
        localPath: r['path'] as String,
        timestamp: r['ts'] as String?,
        uploaded: (r['uploaded'] as int? ?? 0) == 1,
      );
}

class PendingCounts {
  final int photos;
  final int logLines;
  final int invalidTimestamps;
  const PendingCounts({
    required this.photos,
    required this.logLines,
    required this.invalidTimestamps,
  });
}

class LocalStorageService {
  static Database? _db;

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      p.join(dir.path, 'brumaire.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE log_entries (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            seq      INTEGER UNIQUE,
            ts       TEXT NOT NULL,
            ts_valid INTEGER NOT NULL DEFAULT 0,
            etype    TEXT NOT NULL,
            event    TEXT,
            skey     TEXT,
            sval     REAL,
            raw      TEXT NOT NULL,
            uploaded INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE photos (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            filename TEXT UNIQUE NOT NULL,
            path     TEXT NOT NULL,
            ts       TEXT,
            uploaded INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onOpen: (db) async {
        // Índice para buscar los sensores de una foto por timestamp (galería).
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_log_entries_ts ON log_entries(ts)',
        );
        // Metadatos persistentes (p. ej. el seq máximo importado, que no puede
        // depender de log_entries porque sus filas se borran tras subirlas).
        await db.execute(
          'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER)',
        );
      },
    );
  }

  Future<String> _photosDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(dir.path, 'photos'));
    await d.create(recursive: true);
    return d.path;
  }

  /// Escribe a un temporal y lo renombra: si algo falla a mitad de camino no
  /// queda un JPEG incompleto con el nombre final.
  Future<String> savePhotoFile(String filename, Uint8List bytes) async {
    final dir = await _photosDir();
    final path = p.join(dir, filename);
    final tmp = File('$path.part');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    return path;
  }

  /// Borra fotos del teléfono (fila de SQLite y archivo). Las lecturas de
  /// log_entries no se tocan aquí (ver purgeUploadedLogEntries). Primero la fila: si el archivo no se pudiera
  /// borrar solo queda un huérfano, nunca una fila apuntando a la nada.
  Future<void> deletePhotos(List<StoredPhoto> photos) async {
    if (photos.isEmpty) return;
    final db = await _database;
    final ids = photos.map((p) => p.id).toList();
    final ph = List.filled(ids.length, '?').join(',');
    await db.rawDelete('DELETE FROM photos WHERE id IN ($ph)', ids);
    for (final photo in photos) {
      try {
        final f = File(photo.localPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Líneas de evento pendientes de subir (incluido BIRD) y las lecturas de
  /// sensores de esos mismos timestamps (para el visor de eventos Local).
  Future<List<LogEntry>> pendingEventEntries() async {
    final db = await _database;
    const eventWhere = "etype='event' AND uploaded=0";
    final events = await db.query('log_entries', where: eventWhere, orderBy: 'seq ASC');
    final sensors = await db.rawQuery(
      "SELECT * FROM log_entries WHERE etype='sensorData' AND ts_valid=1 "
      'AND ts IN (SELECT ts FROM log_entries WHERE $eventWhere AND ts_valid=1)',
    );
    return [...events.map(_entryFromRow), ...sensors.map(_entryFromRow)];
  }

  /// Borra las lecturas ya subidas, salvo las del mismo instante que una foto
  /// que sigue en el teléfono (la galería Local muestra sus sensores). Se
  /// llama al terminar una subida y tras borrar fotos a mano.
  Future<int> purgeUploadedLogEntries() async {
    final db = await _database;
    final photoRows = await db.query('photos', columns: ['ts']);
    final keep = <String>{};
    for (final r in photoRows) {
      final raw = r['ts'] as String?;
      final t = raw == null ? null : LogParser.parseTimestamp(raw);
      if (t != null) keep.add(t.toIso8601String());
    }
    final rows = await db.query('log_entries', columns: ['id', 'ts'], where: 'uploaded=1');
    final ids = [
      for (final r in rows)
        if (!keep.contains(r['ts'] as String)) r['id'] as int,
    ];
    const chunk = 500;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
      final ph = List.filled(part.length, '?').join(',');
      await db.rawDelete('DELETE FROM log_entries WHERE id IN ($ph)', part);
    }
    return ids.length;
  }

  /// Fotos que quedaron marcadas como subidas (versiones anteriores de la app
  /// no las borraban). Ya están en la nube.
  Future<List<StoredPhoto>> uploadedPhotos() async {
    final db = await _database;
    final rows = await db.query('photos', where: 'uploaded=1');
    return rows.map(StoredPhoto._fromRow).toList();
  }

  /// Devuelve false si la foto ya estaba registrada (mismo nombre).
  Future<bool> insertPhoto(String filename, String localPath, String? ts) async {
    final db = await _database;
    final rowId = await db.insert(
      'photos',
      {'filename': filename, 'path': localPath, 'ts': ts, 'uploaded': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId != 0;
  }

  Future<int> insertLogEntries(List<LogEntry> entries) async {
    if (entries.isEmpty) return 0;
    final db = await _database;
    int count = 0;
    await db.transaction((txn) async {
      int maxSeq = -1;
      for (final e in entries) {
        if (e.seq != null && e.seq! > maxSeq) maxSeq = e.seq!;
        final rowId = await txn.insert(
          'log_entries',
          {
            'seq': e.seq,
            'ts': e.timestamp.toIso8601String(),
            'ts_valid': e.timestampValid ? 1 : 0,
            'etype': e.type.name,
            'event': e.event,
            'skey': e.sensorKey,
            'sval': e.sensorValue,
            'raw': e.rawLine,
            'uploaded': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (rowId != 0) count++;
      }
      // High-water mark en la misma transacción que las filas.
      if (maxSeq >= 0) {
        // Sin UPSERT: SQLite de Android < 11 no lo soporta.
        await txn.rawInsert(
          'INSERT OR IGNORE INTO meta (key, value) VALUES (?, -1)',
          [_keyMaxSeq],
        );
        await txn.rawUpdate(
          'UPDATE meta SET value = MAX(value, ?) WHERE key = ?',
          [maxSeq, _keyMaxSeq],
        );
      }
    });
    return count;
  }

  static const _keyMaxSeq = 'max_seq_importado';

  /// Mayor `seq` importado alguna vez (aunque sus filas ya se hayan borrado
  /// tras subirlas). Considera también MAX(seq) de la tabla para bases de
  /// datos anteriores a la tabla meta. -1 si nunca se importó nada.
  Future<int> maxStoredSeq() async {
    final db = await _database;
    final r = await db.rawQuery(
      'SELECT MAX('
      "  COALESCE((SELECT value FROM meta WHERE key = '$_keyMaxSeq'), -1),"
      '  COALESCE((SELECT MAX(seq) FROM log_entries), -1)'
      ') AS m',
    );
    return (r.first['m'] as int?) ?? -1;
  }

  Future<PendingCounts> pendingCounts() async {
    final db = await _database;
    final photos = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM photos WHERE uploaded=0'),
        ) ??
        0;
    final lines = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM log_entries WHERE uploaded=0'),
        ) ??
        0;
    final invalid = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM log_entries WHERE uploaded=0 AND ts_valid=0',
          ),
        ) ??
        0;
    return PendingCounts(photos: photos, logLines: lines, invalidTimestamps: invalid);
  }

  Future<List<StoredPhoto>> pendingPhotos() async {
    final db = await _database;
    final rows = await db.query('photos', where: 'uploaded=0');
    return rows.map(StoredPhoto._fromRow).toList();
  }

  Future<List<({int id, LogEntry entry})>> pendingLogEntries() async {
    final db = await _database;
    final rows = await db.query(
      'log_entries',
      where: 'uploaded=0',
      orderBy: 'seq ASC',
    );
    return rows.map((r) => (id: r['id'] as int, entry: _entryFromRow(r))).toList();
  }

  Future<void> markPhotosUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final ph = List.filled(ids.length, '?').join(',');
    await db.rawUpdate('UPDATE photos SET uploaded=1 WHERE id IN ($ph)', ids);
  }

  Future<List<StoredPhoto>> allPhotos() async {
    final db = await _database;
    final rows = await db.query('photos', orderBy: 'id DESC');
    return rows.map(StoredPhoto._fromRow).toList();
  }

  static LogEntry _entryFromRow(Map<String, Object?> r) => LogEntry(
        timestamp: DateTime.parse(r['ts'] as String),
        timestampValid: (r['ts_valid'] as int) == 1,
        type: EntryType.values.byName(r['etype'] as String),
        seq: r['seq'] as int?,
        event: r['event'] as String?,
        sensorKey: r['skey'] as String?,
        sensorValue: (r['sval'] as num?)?.toDouble(),
        rawLine: r['raw'] as String,
      );

  Future<List<LogEntry>> allLogEntries() async {
    final db = await _database;
    final rows = await db.query('log_entries', orderBy: 'seq ASC');
    return rows.map(_entryFromRow).toList();
  }

  /// Entradas de log (con timestamp válido) de los instantes dados. Sirve para
  /// cruzar fotos con sensores sin cargar todo el log en memoria.
  Future<List<LogEntry>> logEntriesAt(Iterable<DateTime> timestamps) async {
    final keys = timestamps.map((t) => t.toIso8601String()).toSet().toList();
    if (keys.isEmpty) return [];
    final db = await _database;
    final result = <LogEntry>[];
    const chunk = 500; // SQLite admite máx. 999 parámetros por consulta
    for (var i = 0; i < keys.length; i += chunk) {
      final part = keys.sublist(i, i + chunk > keys.length ? keys.length : i + chunk);
      final ph = List.filled(part.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT * FROM log_entries WHERE ts_valid=1 AND ts IN ($ph) ORDER BY seq ASC',
        part,
      );
      result.addAll(rows.map(_entryFromRow));
    }
    return result;
  }

  Future<void> markLogEntriesUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final ph = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
        'UPDATE log_entries SET uploaded=1 WHERE id IN ($ph)', ids);
  }
}
