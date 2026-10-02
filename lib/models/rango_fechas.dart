// Rango de fechas de las consultas a la nube (galería Cloud y eventos Cloud).
// La API acepta cualquier from/to; los datos duran diasRetencionNube en la nube
// (TTL de DynamoDB y lifecycle de S3), así que no se ofrece ir más atrás.

const diasRetencionNube = 365;

enum RangoPreset {
  hoy('Hoy'),
  semana('7 días'),
  mes('30 días'),
  trimestre('90 días'),
  anio('1 año'),
  personalizado('Personalizado');

  final String etiqueta;
  const RangoPreset(this.etiqueta);
}

String _p(int n) => n.toString().padLeft(2, '0');

class RangoFechas {
  final RangoPreset preset;

  /// Días elegidos en "Personalizado" (inclusive, en hora local; se ignora la hora).
  final DateTime? desde;
  final DateTime? hasta;

  const RangoFechas(this.preset) : desde = null, hasta = null;
  const RangoFechas.personalizado(DateTime this.desde, DateTime this.hasta)
      : preset = RangoPreset.personalizado;

  /// Primer día que se puede pedir (hoy − retención).
  static DateTime primerDia(DateTime now) =>
      DateTime(now.year, now.month, now.day).subtract(const Duration(days: diasRetencionNube));

  /// Intervalo [from, to] para la API.
  ({DateTime from, DateTime to}) resolver({DateTime? now}) {
    final n = now ?? DateTime.now();
    final hoy = DateTime(n.year, n.month, n.day);
    return switch (preset) {
      RangoPreset.hoy => (from: hoy, to: n),
      RangoPreset.semana => (from: n.subtract(const Duration(days: 7)), to: n),
      RangoPreset.mes => (from: n.subtract(const Duration(days: 30)), to: n),
      RangoPreset.trimestre => (from: n.subtract(const Duration(days: 90)), to: n),
      RangoPreset.anio => (from: n.subtract(const Duration(days: diasRetencionNube)), to: n),
      RangoPreset.personalizado => (
          from: DateTime(desde!.year, desde!.month, desde!.day),
          // Hasta el final del último día elegido.
          to: DateTime(hasta!.year, hasta!.month, hasta!.day, 23, 59, 59),
        ),
    };
  }

  /// "7 días" o, si es personalizado, "27/09/2026 – 01/10/2026" (un solo día: "27/09/2026").
  String get etiqueta {
    if (preset != RangoPreset.personalizado) return preset.etiqueta;
    String f(DateTime d) => '${_p(d.day)}/${_p(d.month)}/${d.year}';
    final a = f(desde!), b = f(hasta!);
    return a == b ? a : '$a – $b';
  }
}
