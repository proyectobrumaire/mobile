// Formato de fechas en español sin depender de intl.

const _dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const _meses = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

String _p(int n) => n.toString().padLeft(2, '0');

/// "Hoy", "Ayer" o "Sábado 27 de septiembre" (con año si no es el actual).
String formatDayHeader(DateTime day, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final d = DateTime(day.year, day.month, day.day);
  final diff = today.difference(d).inHours;
  if (diff == 0) return 'Hoy';
  if (diff > 0 && diff <= 25) return 'Ayer'; // tolera cambio de horario
  final dia = _dias[d.weekday - 1];
  final text = '${dia[0].toUpperCase()}${dia.substring(1)} ${d.day} de ${_meses[d.month - 1]}';
  return d.year == n.year ? text : '$text de ${d.year}';
}

String formatTime(DateTime t) => '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';

/// "27/09/2026 08:30:12"
String formatDateTime(DateTime t) =>
    '${_p(t.day)}/${_p(t.month)}/${t.year} ${formatTime(t)}';
