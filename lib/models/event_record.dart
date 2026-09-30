import 'log_entry.dart';

/// Evento del log (local o de la nube) con las lecturas del mismo instante.
class EventRecord {
  /// Hora local.
  final DateTime timestamp;
  final String event;
  final Map<String, double> sensors;

  /// false: el log traía una fecha inválida (la hora no es confiable).
  final bool timestampValid;

  const EventRecord({
    required this.timestamp,
    required this.event,
    this.sensors = const {},
    this.timestampValid = true,
  });

  String get category => eventCategory(event);
  String get label => eventLabelFor(event);
}

/// Categoría de filtro para tipos desconocidos (p. ej. INVALID_EV).
const otrosEventos = 'OTROS';

/// Categorías del filtro del visor (pestaña Local), en orden. Incluye BIRD:
/// al tocar un evento de ave se abren sus fotos.
const eventCategories = ['BIRD', 'PERIODIC', 'BOOT', 'PELTIER_ON', 'PELTIER_OFF', 'VOLCADO', otrosEventos];

/// Categorías de la pestaña Cloud: sin BIRD (las aves están en la galería).
const cloudEventCategories = ['PERIODIC', 'BOOT', 'PELTIER_ON', 'PELTIER_OFF', 'VOLCADO', otrosEventos];

const _knownLabels = {
  'BOOT': 'Arranque del sistema',
  'PERIODIC': 'Reporte periódico',
  'PELTIER_ON': 'Peltier encendida',
  'PELTIER_OFF': 'Peltier apagada',
  'VOLCADO': 'Vaciado del plato',
  'BIRD': 'Ave detectada',
  'INVALID_EV': 'Evento inválido',
};

String eventLabelFor(String event) => _knownLabels[event] ?? 'Evento $event';

String eventCategory(String event) =>
    eventCategories.contains(event) ? event : otrosEventos;

String categoryLabel(String category) => switch (category) {
      otrosEventos => 'Otros',
      'BIRD' => 'Ave',
      _ => eventLabelFor(category),
    };

/// Tipos a pedir a POST /events para las categorías elegidas. Se envían
/// explícitos para que BIRD (muy frecuente) no consuma el límite de 500.
/// "Otros" solo puede pedir los desconocidos que conocemos (INVALID_EV).
List<String> cloudTypesFor(Set<String> categories) => [
      for (final c in cloudEventCategories)
        if (categories.contains(c)) ...(c == otrosEventos ? const ['INVALID_EV'] : [c]),
    ];

/// Eventos (incluido BIRD) armados desde filas de log_entries: cada línea de
/// evento con las lecturas de sensores del mismo timestamp exacto.
List<EventRecord> eventsFromLogEntries(List<LogEntry> entries) {
  final sensorsByTs = <DateTime, Map<String, double>>{};
  for (final e in entries) {
    if (e.type != EntryType.sensorData || !e.timestampValid || e.sensorKey == null) continue;
    sensorsByTs.putIfAbsent(e.timestamp, () => {})[e.sensorKey!] =
        e.sensorValue ?? double.nan;
  }
  return [
    for (final e in entries)
      if (e.type == EntryType.event && e.event != null)
        EventRecord(
          timestamp: e.timestamp,
          event: e.event!,
          timestampValid: e.timestampValid,
          sensors: e.timestampValid ? (sensorsByTs[e.timestamp] ?? const {}) : const {},
        ),
  ];
}

/// Eventos de un día (date == null: fecha inválida).
class EventDay {
  final DateTime? date;
  final List<EventRecord> events;
  const EventDay(this.date, this.events);
}

/// Filtra por categoría y agrupa por día, lo más reciente primero; los de
/// fecha inválida al final. (La pestaña Cloud no incluye la categoría BIRD.)
List<EventDay> groupEventsByDay(List<EventRecord> events, Set<String> categories) {
  final filtered = events
      .where((e) => categories.contains(e.category))
      .toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final byDay = <DateTime?, List<EventRecord>>{};
  for (final e in filtered) {
    final t = e.timestamp;
    final key = e.timestampValid ? DateTime(t.year, t.month, t.day) : null;
    byDay.putIfAbsent(key, () => []).add(e);
  }
  final days = [for (final e in byDay.entries) EventDay(e.key, e.value)]
    ..sort((a, b) {
      if (a.date == null) return 1;
      if (b.date == null) return -1;
      return b.date!.compareTo(a.date!);
    });
  return days;
}

/// Cuántos eventos hay por categoría (para los chips del filtro).
Map<String, int> countByCategory(List<EventRecord> events) {
  final m = <String, int>{};
  for (final e in events) {
    m[e.category] = (m[e.category] ?? 0) + 1;
  }
  return m;
}
