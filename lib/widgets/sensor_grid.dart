import 'package:flutter/material.dart';
import '../models/log_entry.dart';

/// Lecturas de sensores con etiqueta legible y unidad, en dos columnas.
class SensorGrid extends StatelessWidget {
  final Map<String, double> sensors;
  final Color? labelColor;
  final Color? valueColor;

  const SensorGrid({
    super.key,
    required this.sensors,
    this.labelColor,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final keys = orderedSensorKeys(sensors.keys);
    final theme = Theme.of(context).textTheme;
    return LayoutBuilder(builder: (context, constraints) {
      final width = (constraints.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          for (final k in keys)
            SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sensorLabels[k] ?? k,
                    style: theme.labelSmall?.copyWith(color: labelColor ?? Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    formatSensorValue(k, sensors[k]),
                    style: theme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: valueColor,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }
}
