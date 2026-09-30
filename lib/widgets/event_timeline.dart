import 'package:flutter/material.dart';
import '../models/event_record.dart';
import '../models/fechas.dart';
import '../models/log_entry.dart';
import 'sensor_grid.dart';

/// Icono y color por tipo de evento (genérico para los desconocidos).
({IconData icon, Color color}) eventStyle(String event) => switch (event) {
      'BOOT' => (icon: Icons.power_settings_new, color: Colors.deepPurple),
      'PERIODIC' => (icon: Icons.schedule, color: Colors.blue),
      'PELTIER_ON' => (icon: Icons.ac_unit, color: Colors.cyan.shade700),
      'PELTIER_OFF' => (icon: Icons.mode_standby, color: Colors.blueGrey),
      'VOLCADO' => (icon: Icons.water_drop, color: Colors.teal),
      'BIRD' => (icon: Icons.flutter_dash, color: Colors.green),
      _ => (icon: Icons.help_outline, color: Colors.grey.shade600),
    };

/// Chips de filtro por categoría de evento (selección múltiple).
class EventFilterChips extends StatelessWidget {
  final Set<String> selected;
  final Map<String, int>? counts;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;
  final List<String> categories;

  const EventFilterChips({
    this.categories = eventCategories,
    super.key,
    required this.selected,
    required this.onChanged,
    this.counts,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: Icon(eventStyle(c).icon, size: 16, color: eventStyle(c).color),
                label: Text(counts != null
                    ? '${categoryLabel(c)} (${counts![c] ?? 0})'
                    : categoryLabel(c)),
                selected: selected.contains(c),
                showCheckmark: false,
                onSelected: enabled
                    ? (v) => onChanged(
                        v ? ({...selected, c}) : (selected.where((x) => x != c).toSet()))
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// Línea de tiempo de eventos agrupada por día.
class EventTimeline extends StatelessWidget {
  final List<EventDay> days;
  final Widget? header;
  final String emptyMessage;
  final Future<void> Function()? onRefresh;

  /// Acción al tocar un evento (por defecto, el detalle con sensores).
  final void Function(BuildContext context, EventRecord event)? onTapEvent;

  const EventTimeline({
    super.key,
    required this.days,
    this.header,
    this.emptyMessage = 'Sin eventos.',
    this.onRefresh,
    this.onTapEvent,
  });

  @override
  Widget build(BuildContext context) {
    final items = <Object>[
      for (final d in days) ...[d, ...d.events],
    ];
    final list = ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(
            children: [
              ?header,
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 64, 24, 0),
                  child: Text(emptyMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey)),
                ),
            ],
          );
        }
        final item = items[i - 1];
        if (item is EventDay) return _DayHeader(day: item);
        final ev = item as EventRecord;
        final next = i < items.length ? items[i] : null;
        return _EventRow(
          event: ev,
          isLastOfDay: next == null || next is EventDay,
          onTap: () => onTapEvent != null
              ? onTapEvent!(context, ev)
              : showEventDetail(context, ev),
        );
      },
    );
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

class _DayHeader extends StatelessWidget {
  final EventDay day;
  const _DayHeader({required this.day});

  @override
  Widget build(BuildContext context) {
    final n = day.events.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Row(
        children: [
          Text(
            day.date != null ? formatDayHeader(day.date!) : 'Fecha no válida',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Text(n == 1 ? '1 evento' : '$n eventos',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
        ],
      ),
    );
  }
}

/// Resumen corto de sensores para la fila (temperatura, humedad, PWM, peso).
String sensorSummary(Map<String, double> sensors) {
  const keys = ['T1_K', 'H1_K', 'P2_K', 'W1_K', 'L1_K'];
  return [
    for (final k in keys)
      if (sensors.containsKey(k))
        switch (k) {
          'P2_K' => 'PWM ${formatSensorValue(k, sensors[k]).split(' ').first}',
          // Sí/No solo no se entiende sin la etiqueta.
          'L1_K' => 'Lluvia: ${formatSensorValue(k, sensors[k])}',
          _ => formatSensorValue(k, sensors[k]),
        },
  ].join(' · ');
}

class _EventRow extends StatelessWidget {
  final EventRecord event;
  final bool isLastOfDay;
  final VoidCallback onTap;

  const _EventRow({required this.event, required this.isLastOfDay, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final style = eventStyle(event.event);
    final text = Theme.of(context).textTheme;
    final summary = sensorSummary(event.sensors);
    final lineColor = Colors.grey.shade300;
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Ancho mínimo para alinear las horas, pero crece si la fuente del
            // sistema es grande (no corta la hora).
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 72),
              child: Padding(
                padding: const EdgeInsets.only(top: 12, left: 16),
                child: Text(
                  event.timestampValid ? formatTime(event.timestamp) : '--:--:--',
                  style: text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  Container(width: 2, height: 8, color: lineColor),
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: style.color.withValues(alpha: 0.15),
                    child: Icon(style.icon, size: 16, color: style.color),
                  ),
                  Expanded(
                    child: Container(width: 2, color: isLastOfDay ? Colors.transparent : lineColor),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event.label,
                        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      summary.isEmpty ? 'Sin lecturas' : summary,
                      style: text.bodySmall?.copyWith(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            if (event.event == 'BIRD')
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Icon(Icons.photo_library_outlined, size: 20, color: style.color),
              ),
          ],
        ),
      ),
    );
  }
}

/// Detalle de un evento con todas sus lecturas.
Future<void> showEventDetail(BuildContext context, EventRecord event) {
  final style = eventStyle(event.event);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final text = Theme.of(ctx).textTheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: style.color.withValues(alpha: 0.15),
                      child: Icon(style.icon, color: style.color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(event.label, style: text.titleMedium),
                          Text(
                            event.timestampValid
                                ? '${formatDayHeader(event.timestamp)} · ${formatTime(event.timestamp)}'
                                : 'Fecha no válida en el registro',
                            style: text.bodySmall?.copyWith(color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Código: ${event.event}',
                    style: text.labelSmall?.copyWith(color: Colors.grey.shade600)),
                const Divider(height: 24),
                if (event.sensors.isEmpty)
                  Text('Sin lecturas de sensores para este instante.',
                      style: text.bodySmall?.copyWith(color: Colors.grey.shade600))
                else
                  SensorGrid(sensors: event.sensors),
              ],
            ),
          ),
        ),
      );
    },
  );
}
