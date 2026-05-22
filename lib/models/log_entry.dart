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
};

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
