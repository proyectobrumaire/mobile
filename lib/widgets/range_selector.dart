import 'package:flutter/material.dart';
import '../models/rango_fechas.dart';

/// Chips de rango de fechas para las consultas a la nube. "Personalizado" abre
/// un calendario (desde hoy − retención de la nube hasta hoy) y muestra el rango elegido.
class RangeSelector extends StatelessWidget {
  final RangoFechas value;
  final bool enabled;
  final ValueChanged<RangoFechas> onChanged;

  const RangeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  Future<void> _elegirPersonalizado(BuildContext context) async {
    final now = DateTime.now();
    final hoy = DateTime(now.year, now.month, now.day);
    final actual = value.preset == RangoPreset.personalizado
        ? DateTimeRange(start: value.desde!, end: value.hasta!)
        : DateTimeRange(start: hoy.subtract(const Duration(days: 7)), end: hoy);
    final r = await showDateRangePicker(
      context: context,
      firstDate: RangoFechas.primerDia(now),
      lastDate: hoy,
      initialDateRange: actual,
      helpText: 'Rango de fechas',
      saveText: 'Aplicar',
    );
    if (r != null) onChanged(RangoFechas.personalizado(r.start, r.end));
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final p in RangoPreset.values)
          ChoiceChip(
            label: Text(p == RangoPreset.personalizado && value.preset == p
                ? value.etiqueta
                : p.etiqueta),
            avatar: p == RangoPreset.personalizado ? const Icon(Icons.date_range, size: 18) : null,
            selected: value.preset == p,
            onSelected: !enabled
                ? null
                : (_) {
                    if (p == RangoPreset.personalizado) {
                      _elegirPersonalizado(context);
                    } else {
                      onChanged(RangoFechas(p));
                    }
                  },
          ),
      ],
    );
  }
}
