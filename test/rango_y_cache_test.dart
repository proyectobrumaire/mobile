import 'package:brumaire_mobile/models/rango_fechas.dart';
import 'package:brumaire_mobile/services/cloud_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cloudImageCacheKey', () {
    test('quita la firma: misma foto con otra firma → misma clave', () {
      const a = 'https://brumaire-data.s3.amazonaws.com/images/raw/image_26-10-01T21-20-00_0.jpg'
          '?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20261001T212000Z&X-Amz-Signature=aaa';
      const b = 'https://brumaire-data.s3.amazonaws.com/images/raw/image_26-10-01T21-20-00_0.jpg'
          '?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20261002T080000Z&X-Amz-Signature=bbb';
      expect(cloudImageCacheKey(a), cloudImageCacheKey(b));
      expect(cloudImageCacheKey(a),
          'https://brumaire-data.s3.amazonaws.com/images/raw/image_26-10-01T21-20-00_0.jpg');
    });

    test('fotos distintas → claves distintas; URL sin query queda igual', () {
      const raw = 'https://b.s3.amazonaws.com/images/raw/x_0.jpg?sig=1';
      const proc = 'https://b.s3.amazonaws.com/images/processed/x_0.jpg?sig=1';
      expect(cloudImageCacheKey(raw), isNot(cloudImageCacheKey(proc)));
      expect(cloudImageCacheKey('https://b/x.jpg'), 'https://b/x.jpg');
    });
  });

  group('RangoFechas', () {
    final now = DateTime(2026, 10, 1, 21, 30);

    test('presets', () {
      expect(const RangoFechas(RangoPreset.hoy).resolver(now: now),
          (from: DateTime(2026, 10, 1), to: now));
      expect(const RangoFechas(RangoPreset.trimestre).resolver(now: now).from,
          now.subtract(const Duration(days: 90)));
      expect(const RangoFechas(RangoPreset.anio).resolver(now: now).from,
          now.subtract(const Duration(days: diasRetencionNube)));
      expect(const RangoFechas(RangoPreset.mes).etiqueta, '30 días');
    });

    test('personalizado: días completos, inclusive', () {
      final r = RangoFechas.personalizado(DateTime(2026, 9, 27), DateTime(2026, 9, 29));
      expect(r.resolver(now: now),
          (from: DateTime(2026, 9, 27), to: DateTime(2026, 9, 29, 23, 59, 59)));
      expect(r.etiqueta, '27/09/2026 – 29/09/2026');
      expect(RangoFechas.personalizado(DateTime(2026, 9, 27), DateTime(2026, 9, 27)).etiqueta,
          '27/09/2026');
    });

    test('primer día elegible = hoy − retención', () {
      expect(RangoFechas.primerDia(now), DateTime(2025, 10, 1));
    });
  });
}
