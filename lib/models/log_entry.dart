enum EntryType { event, sensorData }

const sensorLabels = {
  'T1_K': 'Temp. ambiente',
  'T2_K': 'Temp. caja interna',
  'T3_K': 'Placa fría 1',
  'T4_K': 'Placa fría 2',
  'T5_K': 'Temp. media fría',
  'T6_K': 'Temp. objetivo',
  'H1_K': 'Humedad externa',
  'H2_K': 'Humedad interna',
  'E1_K': 'Error',
  'E2_K': 'Error acumulado',
  'P1_K': 'Punto de rocío',
  'P2_K': 'PWM aplicado',
  'I1_K': 'Corriente Panel',
  'I2_K': 'Corriente Turbina',
  'I3_K': 'Corriente Batería',
  'I4_K': 'Corriente filtrada',
  'W1_K': 'Peso del agua',
  'L1_K': 'Lluvia',
};

/// Orden en que se muestran los sensores (el del Arduino; las claves antiguas
/// al final). Claves desconocidas van después de estas.
const sensorOrder = [
  'T1_K', 'T2_K', 'T3_K', 'T4_K', 'T5_K', 'T6_K',
  'H1_K', 'H2_K', 'P1_K', 'P2_K', 'I4_K', 'W1_K', 'L1_K',
  'E1_K', 'E2_K', 'I1_K', 'I2_K', 'I3_K',
];

/// Unidad de cada sensor. P2_K es el PWM de la Peltier (0–255) y se formatea aparte.
const sensorUnits = {
  'T1_K': '°C', 'T2_K': '°C', 'T3_K': '°C', 'T4_K': '°C', 'T5_K': '°C',
  'T6_K': '°C', 'E1_K': '°C', 'E2_K': '°C', 'P1_K': '°C',
  'H1_K': '%', 'H2_K': '%',
  'I1_K': 'A', 'I2_K': 'A', 'I3_K': 'A', 'I4_K': 'A',
  'W1_K': 'g',
};

/// Claves ordenadas según [sensorOrder].
List<String> orderedSensorKeys(Iterable<String> keys) {
  final set = keys.toSet();
  return [
    ...sensorOrder.where(set.contains),
    ...set.where((k) => !sensorOrder.contains(k)).toList()..sort(),
  ];
}

/// Valor legible con unidad, p. ej. "24.5 °C", "0.35 A", "128 / 255 (50 %)".
/// null o NaN (sensor sin lectura) → "sin lectura".
/// Sensores booleanos (1.0 = sí, 0.0 = no; último estado, no promedio).
const booleanSensors = {'L1_K'};

/// true/false para un sensor booleano; null si no hay lectura válida.
bool? sensorBool(double? value) =>
    (value == null || value.isNaN || value.isInfinite) ? null : value >= 0.5;

String formatSensorValue(String key, double? value) {
  if (value == null || value.isNaN || value.isInfinite) return 'sin lectura';
  if (booleanSensors.contains(key)) return value >= 0.5 ? 'Sí' : 'No';
  if (key == 'P2_K') {
    final pwm = value.round();
    return '$pwm / 255 (${(pwm * 100 / 255).round()} %)';
  }
  final unit = sensorUnits[key];
  final decimals = switch (unit) {
    'A' => 2,
    'g' => 0,
    _ => 1,
  };
  final text = value.toStringAsFixed(decimals);
  return unit == null ? text : '$text $unit';
}

class LogEntry {
  final DateTime timestamp;
  final bool timestampValid;
  final EntryType type;
  final int? seq;
  final String? event;
  final String? sensorKey;
  final double? sensorValue;
  final String rawLine;

  const LogEntry({
    required this.timestamp,
    required this.timestampValid,
    required this.type,
    this.seq,
    this.event,
    this.sensorKey,
    this.sensorValue,
    required this.rawLine,
  });

  String? get sensorLabel => sensorKey != null ? sensorLabels[sensorKey] ?? sensorKey : null;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'timestamp_valid': timestampValid,
        'type': type.name,
        if (seq != null) 'seq': seq,
        if (event != null) 'event': event,
        if (sensorKey != null) 'sensor_key': sensorKey,
        if (sensorValue != null) 'sensor_value': sensorValue,
      };
}
