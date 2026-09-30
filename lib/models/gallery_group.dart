import '../services/local_storage_service.dart';
import '../services/log_parser.dart';
import 'log_entry.dart';

/// Fotos de un mismo evento (mismo timestamp) con los sensores de ese instante.
class GalleryGroup {
  final String timestampRaw;
  final DateTime? timestamp;
  final List<StoredPhoto> photos;
  final String? eventType;

  /// Clave → valor. NaN si el sensor no tuvo lectura.
  final Map<String, double> sensors;

  const GalleryGroup({
    required this.timestampRaw,
    required this.photos,
    this.timestamp,
    this.eventType,
    this.sensors = const {},
  });

  bool get hasSensorData => sensors.isNotEmpty;
  int get uploadedCount => photos.where((p) => p.uploaded).length;
  bool get allUploaded => uploadedCount == photos.length;
}

/// Un día de la galería (date == null: fotos sin fecha reconocible).
class GalleryDay {
  final DateTime? date;
  final List<GalleryGroup> groups;
  const GalleryDay(this.date, this.groups);

  int get photoCount => groups.fold(0, (s, g) => s + g.photos.length);
}

/// Timestamp de una foto (formato compacto del firmware) o null.
DateTime? photoDateTime(StoredPhoto p) =>
    p.timestamp == null ? null : LogParser.parseTimestamp(p.timestamp!);

/// Fotos del evento con ese timestamp exacto (`image_<ts>_0/1/2`), en orden.
List<StoredPhoto> photosForEvent(List<StoredPhoto> photos, DateTime timestamp) =>
    photos.where((p) => photoDateTime(p) == timestamp).toList()
      ..sort((a, b) => a.filename.compareTo(b.filename));

/// Agrupa fotos por evento (timestamp) y los eventos por día.
/// Días y eventos de más reciente a más antiguo; "sin fecha" al final.
/// `entries` son las entradas de log (se cruzan por timestamp exacto).
List<GalleryDay> buildGalleryDays(List<StoredPhoto> photos, List<LogEntry> entries) {
  final photosByTs = <String, List<StoredPhoto>>{};
  for (final p in photos) {
    photosByTs.putIfAbsent(p.timestamp ?? '', () => []).add(p);
  }

  final entriesByTs = <DateTime, List<LogEntry>>{};
  for (final e in entries.where((e) => e.timestampValid)) {
    entriesByTs.putIfAbsent(e.timestamp, () => []).add(e);
  }

  final groups = photosByTs.entries.map((entry) {
    final ts = entry.key.isEmpty ? null : LogParser.parseTimestamp(entry.key);
    final matching = ts != null ? (entriesByTs[ts] ?? const <LogEntry>[]) : const <LogEntry>[];
    final event = matching.where((e) => e.type == EntryType.event).firstOrNull?.event;
    final sensors = <String, double>{};
    for (final e in matching.where((e) => e.type == EntryType.sensorData)) {
      if (e.sensorKey != null) sensors[e.sensorKey!] = e.sensorValue ?? double.nan;
    }
    return GalleryGroup(
      timestampRaw: entry.key,
      timestamp: ts,
      photos: entry.value..sort((a, b) => a.filename.compareTo(b.filename)),
      eventType: event,
      sensors: sensors,
    );
  }).toList();

  final byDay = <DateTime?, List<GalleryGroup>>{};
  for (final g in groups) {
    final t = g.timestamp;
    final day = t == null ? null : DateTime(t.year, t.month, t.day);
    byDay.putIfAbsent(day, () => []).add(g);
  }

  final days = byDay.entries.map((e) {
    final list = e.value
      ..sort((a, b) {
        if (a.timestamp == null || b.timestamp == null) {
          return a.timestampRaw.compareTo(b.timestampRaw);
        }
        return b.timestamp!.compareTo(a.timestamp!);
      });
    return GalleryDay(e.key, list);
  }).toList()
    ..sort((a, b) {
      if (a.date == null) return 1;
      if (b.date == null) return -1;
      return b.date!.compareTo(a.date!);
    });
  return days;
}
