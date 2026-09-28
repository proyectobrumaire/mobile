import 'dart:convert';
import 'package:http/http.dart' as http;

// Cliente de la API de consulta de la nube (API Gateway, mismo host que el
// presigner, header x-api-key). Contrato: .claude/contracts/api-fotos-eventos.md
//   POST /gallery → detecciones de aves por especie (formato original)
//   POST /photos  → todas las fotos subidas
//   POST /events  → eventos del log

Map<String, double> _parseEnv(Object? raw) {
  if (raw is! Map) return const {};
  final env = <String, double>{};
  raw.forEach((k, v) {
    if (v is num) env['$k'] = v.toDouble();
  });
  return env;
}

class CloudDetection {
  final String filename;
  final String species;
  final double confidence;
  final double detectorScore;
  final DateTime timestamp;
  final String? imageUrl;
  final Map<String, double> env;

  const CloudDetection({
    required this.filename,
    required this.species,
    required this.confidence,
    required this.detectorScore,
    required this.timestamp,
    this.imageUrl,
    required this.env,
  });

  factory CloudDetection.fromJson(Map<String, dynamic> j) {
    return CloudDetection(
      filename:      j['filename'] as String,
      species:       j['species'] as String,
      confidence:    (j['confidence'] as num).toDouble(),
      detectorScore: (j['detector_score'] as num).toDouble(),
      timestamp:     DateTime.parse(j['timestamp'] as String),
      imageUrl:      j['image_url'] as String?,
      env:           _parseEnv(j['env']),
    );
  }
}

/// Ave detectada dentro de una foto de POST /photos.
class BirdDetection {
  final String species;
  final double confidence;
  final double? detectorScore;
  const BirdDetection({required this.species, required this.confidence, this.detectorScore});

  factory BirdDetection.fromJson(Map<String, dynamic> j) => BirdDetection(
        species: j['species'] as String,
        confidence: (j['confidence'] as num).toDouble(),
        detectorScore: (j['detector_score'] as num?)?.toDouble(),
      );
}

/// Evento del log en la nube (POST /events).
class CloudEvent {
  final DateTime timestamp;
  final String event;
  final Map<String, double> env;
  const CloudEvent({required this.timestamp, required this.event, this.env = const {}});

  factory CloudEvent.fromJson(Map<String, dynamic> j) => CloudEvent(
        timestamp: DateTime.parse(j['timestamp'] as String),
        event: j['event'] as String,
        env: _parseEnv(j['env']),
      );
}

/// Respuesta paginada por límite: si `truncated`, había más de 500 elementos.
class CloudPage<T> {
  final List<T> items;
  final bool truncated;
  const CloudPage(this.items, {this.truncated = false});
}

/// Error HTTP de la API de consulta (lo traduce ErrorMessages.cloud).
class CloudApiException implements Exception {
  final String path;
  final int statusCode;
  final String? serverMessage;
  const CloudApiException(this.path, this.statusCode, [this.serverMessage]);

  @override
  String toString() =>
      'POST $path falló: $statusCode${serverMessage != null ? ' ($serverMessage)' : ''}';
}

class CloudGalleryService {
  final String presignerUrl;
  final String secret;
  final http.Client? client;

  CloudGalleryService(this.presignerUrl, this.secret, {this.client});

  Uri _uri(String path) {
    final base = presignerUrl.endsWith('/')
        ? presignerUrl.substring(0, presignerUrl.length - 1)
        : presignerUrl;
    return Uri.parse('$base$path');
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final uri = _uri(path);
    final headers = {'Content-Type': 'application/json', 'x-api-key': secret};
    final encoded = jsonEncode(body);
    final c = client;
    final res = await (c != null
            ? c.post(uri, headers: headers, body: encoded)
            : http.post(uri, headers: headers, body: encoded))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      String? msg;
      try {
        msg = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String?;
      } catch (_) {}
      throw CloudApiException(path, res.statusCode, msg);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Map<String, dynamic> _range(DateTime from, DateTime to) => {
        'from': from.toUtc().toIso8601String(),
        'to':   to.toUtc().toIso8601String(),
      };

  /// POST /gallery: detecciones de aves agrupadas por especie.
  Future<Map<String, List<CloudDetection>>> fetch({
    required DateTime from,
    required DateTime to,
    String? species,
  }) async {
    final data = await _post('/gallery', {..._range(from, to), 'species': species});
    return data.map((species, list) {
      final detections = (list as List)
          .map((e) => CloudDetection.fromJson(e as Map<String, dynamic>))
          .toList();
      return MapEntry(species, detections);
    });
  }

  /// POST /photos: todas las fotos subidas (con o sin aves).
  Future<CloudPage<CloudPhoto>> fetchPhotos({required DateTime from, required DateTime to}) async {
    final data = await _post('/photos', _range(from, to));
    return parsePhotos(data);
  }

  static CloudPage<CloudPhoto> parsePhotos(Map<String, dynamic> data) => CloudPage(
        [
          for (final p in (data['photos'] as List? ?? const []))
            CloudPhoto.fromPhotosJson(p as Map<String, dynamic>),
        ],
        truncated: data['truncated'] == true,
      );

  /// POST /events. `types` null = todos los tipos.
  Future<CloudPage<CloudEvent>> fetchEvents({
    required DateTime from,
    required DateTime to,
    List<String>? types,
  }) async {
    final data = await _post('/events', {
      ..._range(from, to),
      'types': ?types,
    });
    return parseEvents(data);
  }

  static CloudPage<CloudEvent> parseEvents(Map<String, dynamic> data) => CloudPage(
        [
          for (final e in (data['events'] as List? ?? const []))
            CloudEvent.fromJson(e as Map<String, dynamic>),
        ],
        truncated: data['truncated'] == true,
      );
}

// ─── Fuentes de la galería cloud ─────────────────────────────────────────────
// La pestaña Cloud trabaja con CloudPhoto y una lista de fuentes registradas en
// cloudGallerySources() (la primera es la opción por defecto); con más de una,
// la pestaña muestra un selector.

/// Foto en la nube, independiente de la fuente.
class CloudPhoto {
  final String filename;

  /// Imagen anotada (_pred.png) si existe.
  final String? imageUrl;

  /// Foto original (.jpg).
  final String? rawUrl;
  final DateTime timestamp;
  final List<BirdDetection> detections;
  final Map<String, double> env;

  const CloudPhoto({
    required this.filename,
    required this.timestamp,
    this.imageUrl,
    this.rawUrl,
    this.detections = const [],
    this.env = const {},
  });

  /// URL a mostrar: la anotada si existe, si no la original.
  String? get displayUrl => imageUrl ?? rawUrl;

  /// Detección principal (mayor confianza), si hay.
  BirdDetection? get topDetection => detections.isEmpty
      ? null
      : detections.reduce((a, b) => b.confidence > a.confidence ? b : a);

  String? get species => topDetection?.species;
  double? get confidence => topDetection?.confidence;

  factory CloudPhoto.fromDetection(CloudDetection d) => CloudPhoto(
        filename: d.filename,
        imageUrl: d.imageUrl,
        timestamp: d.timestamp,
        detections: [
          BirdDetection(species: d.species, confidence: d.confidence, detectorScore: d.detectorScore),
        ],
        env: d.env,
      );

  factory CloudPhoto.fromPhotosJson(Map<String, dynamic> j) => CloudPhoto(
        filename: j['filename'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        imageUrl: j['image_url'] as String?,
        rawUrl: j['raw_url'] as String?,
        detections: [
          for (final d in (j['detections'] as List? ?? const []))
            BirdDetection.fromJson(d as Map<String, dynamic>),
        ],
        env: _parseEnv(j['env']),
      );
}

enum CloudGrouping { porEspecie, porDia }

abstract class CloudGallerySource {
  String get label;
  CloudGrouping get grouping;
  String get emptyMessage;
  Future<CloudPage<CloudPhoto>> fetch({required DateTime from, required DateTime to});
}

/// Todas las fotos subidas (POST /photos), por día.
class AllPhotosSource implements CloudGallerySource {
  final CloudGalleryService service;
  AllPhotosSource(this.service);

  @override
  String get label => 'Todas';

  @override
  CloudGrouping get grouping => CloudGrouping.porDia;

  @override
  String get emptyMessage => 'No hay fotos subidas en este período.';

  @override
  Future<CloudPage<CloudPhoto>> fetch({required DateTime from, required DateTime to}) =>
      service.fetchPhotos(from: from, to: to);
}

/// Detecciones de aves clasificadas (POST /gallery), por especie.
class BirdDetectionsSource implements CloudGallerySource {
  final CloudGalleryService service;
  BirdDetectionsSource(this.service);

  @override
  String get label => 'Aves';

  @override
  CloudGrouping get grouping => CloudGrouping.porEspecie;

  @override
  String get emptyMessage => 'Sin aves detectadas en este período.';

  @override
  Future<CloudPage<CloudPhoto>> fetch({required DateTime from, required DateTime to}) async {
    final data = await service.fetch(from: from, to: to);
    return CloudPage([
      for (final list in data.values) ...list.map(CloudPhoto.fromDetection),
    ]);
  }
}

/// Fuentes de la pestaña Cloud; la primera es la opción por defecto.
List<CloudGallerySource> cloudGallerySources(String presignerUrl, String secret) {
  final service = CloudGalleryService(presignerUrl, secret);
  return [AllPhotosSource(service), BirdDetectionsSource(service)];
}
