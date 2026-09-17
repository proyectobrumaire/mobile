import 'dart:convert';
import 'package:http/http.dart' as http;

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
    final rawEnv = (j['env'] as Map<String, dynamic>?) ?? {};
    final env = rawEnv.map((k, v) => MapEntry(k, (v as num).toDouble()));
    return CloudDetection(
      filename:      j['filename'] as String,
      species:       j['species'] as String,
      confidence:    (j['confidence'] as num).toDouble(),
      detectorScore: (j['detector_score'] as num).toDouble(),
      timestamp:     DateTime.parse(j['timestamp'] as String),
      imageUrl:      j['image_url'] as String?,
      env:           env,
    );
  }
}

class CloudGalleryService {
  final String presignerUrl;
  final String secret;

  CloudGalleryService(this.presignerUrl, this.secret);

  String get _galleryUrl {
    final base = presignerUrl.endsWith('/')
        ? presignerUrl.substring(0, presignerUrl.length - 1)
        : presignerUrl;
    return '$base/gallery';
  }

  Future<Map<String, List<CloudDetection>>> fetch({
    required DateTime from,
    required DateTime to,
    String? species,
  }) async {
    final body = <String, dynamic>{
      'from': from.toUtc().toIso8601String(),
      'to':   to.toUtc().toIso8601String(),
      'species': species,
    };

    final res = await http
        .post(
          Uri.parse(_galleryUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': secret,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    if (res.statusCode != 200) {
      throw Exception('Gallery API error ${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data.map((species, list) {
      final detections = (list as List)
          .map((e) => CloudDetection.fromJson(e as Map<String, dynamic>))
          .toList();
      return MapEntry(species, detections);
    });
  }
}
