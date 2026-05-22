import '../models/log_entry.dart';

class LogParser {
  static const int _minYear = 2020;
  static const int _maxYear = 2035;

  static DateTime? _parseTimestamp(String ts) {
    final sides = ts.split('T');
    if (sides.length != 2) return null;
    final d = sides[0].split('-');
    final t = sides[1].split('-');
    if (d.length != 3 || t.length != 3) return null;
    try {
      final year = 2000 + int.parse(d[0]);
      final month = int.parse(d[1]);
      final day = int.parse(d[2]);
      final hour = int.parse(t[0]);
      final min = int.parse(t[1]);
      final sec = int.parse(t[2]);

      if (year < _minYear || year > _maxYear) return null;
      if (month < 1 || month > 12) return null;
      if (day < 1 || day > 31) return null;
      if (hour > 23 || min > 59 || sec > 59) return null;

      return DateTime(year, month, day, hour, min, sec);
    } catch (_) {
      return null;
    }
  }

  static List<LogEntry> parse(String content) {
    final entries = <LogEntry>[];

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final cols = line.split(',');

      // V2: TS,seq,event_or_dash,sensor_or_dash,value  (5 cols, cols[1] es número)
      // V1: TS,event_or_dash,sensor_or_dash,value      (4 cols)
      final isV2 = cols.length >= 5 && int.tryParse(cols[1].trim()) != null;

      if (!isV2 && cols.length < 4) continue;

      final parsed = _parseTimestamp(cols[0].trim());
      final timestamp = parsed ?? DateTime.now();
      final timestampValid = parsed != null;

      int? seq;
      String col1, col2, col3;

      if (isV2) {
        seq  = int.tryParse(cols[1].trim());
        col1 = cols[2].trim();
        col2 = cols[3].trim();
        col3 = cols[4].trim();
      } else {
        col1 = cols[1].trim();
        col2 = cols[2].trim();
        col3 = cols[3].trim();
      }

      if (col1 == '-') {
        entries.add(LogEntry(
          timestamp: timestamp,
          timestampValid: timestampValid,
          type: EntryType.sensorData,
          seq: seq,
          sensorKey: col2,
          sensorValue: double.tryParse(col3),
          rawLine: line,
        ));
      } else {
        entries.add(LogEntry(
          timestamp: timestamp,
          timestampValid: timestampValid,
          type: EntryType.event,
          seq: seq,
          event: col1,
          rawLine: line,
        ));
      }
    }

    return entries;
  }
}
