import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/log_entry.dart';

class StoredPhoto {
  final int id;
  final String filename;
  final String localPath;
  final String? timestamp;
  const StoredPhoto({
    required this.id,
    required this.filename,
    required this.localPath,
    this.timestamp,
  });
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
    );
  }

  Future<String> _photosDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(dir.path, 'photos'));
    await d.create(recursive: true);
    return d.path;
  }

  Future<String> savePhotoFile(String filename, Uint8List bytes) async {
    final dir = await _photosDir();
    final file = File(p.join(dir, filename));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<void> insertPhoto(String filename, String localPath, String? ts) async {
    final db = await _database;
    await db.insert(
      'photos',
      {'filename': filename, 'path': localPath, 'ts': ts, 'uploaded': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> insertLogEntries(List<LogEntry> entries) async {
    if (entries.isEmpty) return 0;
    final db = await _database;
    int count = 0;
    await db.transaction((txn) async {
      for (final e in entries) {
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
    });
    return count;
  }

  Future<int> maxStoredSeq() async {
    final db = await _database;
    final r = await db.rawQuery('SELECT MAX(seq) AS m FROM log_entries');
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
    return rows
        .map((r) => StoredPhoto(
              id: r['id'] as int,
              filename: r['filename'] as String,
              localPath: r['path'] as String,
              timestamp: r['ts'] as String?,
            ))
        .toList();
  }

  Future<List<({int id, LogEntry entry})>> pendingLogEntries() async {
    final db = await _database;
    final rows = await db.query(
      'log_entries',
      where: 'uploaded=0',
      orderBy: 'seq ASC',
    );
    return rows.map((r) {
      final entry = LogEntry(
        timestamp: DateTime.parse(r['ts'] as String),
        timestampValid: (r['ts_valid'] as int) == 1,
        type: EntryType.values.byName(r['etype'] as String),
        seq: r['seq'] as int?,
        event: r['event'] as String?,
        sensorKey: r['skey'] as String?,
        sensorValue: r['sval'] as double?,
        rawLine: r['raw'] as String,
      );
      return (id: r['id'] as int, entry: entry);
    }).toList();
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
    return rows
        .map((r) => StoredPhoto(
              id: r['id'] as int,
              filename: r['filename'] as String,
              localPath: r['path'] as String,
              timestamp: r['ts'] as String?,
            ))
        .toList();
  }

  Future<List<LogEntry>> allLogEntries() async {
    final db = await _database;
    final rows = await db.query('log_entries', orderBy: 'seq ASC');
    return rows
        .map((r) => LogEntry(
              timestamp: DateTime.parse(r['ts'] as String),
              timestampValid: (r['ts_valid'] as int) == 1,
              type: EntryType.values.byName(r['etype'] as String),
              seq: r['seq'] as int?,
              event: r['event'] as String?,
              sensorKey: r['skey'] as String?,
              sensorValue: r['sval'] as double?,
              rawLine: r['raw'] as String,
            ))
        .toList();
  }

  Future<void> markLogEntriesUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _database;
    final ph = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
        'UPDATE log_entries SET uploaded=1 WHERE id IN ($ph)', ids);
  }
}
