import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/log_entry.dart';

// Sube archivos a S3 en dos pasos:
// 1. POST al presigner (Lambda) para obtener una URL firmada
// 2. PUT directo a S3 usando esa URL
class BackendService {
  final String presignerUrl;
  final String secret;

  BackendService(this.presignerUrl, this.secret);

  Future<void> uploadPhoto(
    Uint8List bytes,
    String filename,
    DateTime timestamp,
  ) async {
    final signedUrl = await _getSignedUrl(
      type: 'image',
      filename: filename,
      date: _dateStr(timestamp),
    );

    final res = await http
        .put(Uri.parse(signedUrl), body: bytes)
        .timeout(const Duration(seconds: 60));

    if (res.statusCode != 200) {
      throw Exception('Upload foto a S3 falló: ${res.statusCode}');
    }
  }

  Future<void> uploadLogs(List<LogEntry> entries) async {
    if (entries.isEmpty) return;

    final now = DateTime.now().toUtc();
    final filename = 'batch_${now.millisecondsSinceEpoch}.json';

    final signedUrl = await _getSignedUrl(
      type: 'app_log',
      filename: filename,
      date: _dateStr(now),
    );

    final body = jsonEncode({'entries': entries.map((e) => e.toJson()).toList()});
    final res = await http
        .put(
          Uri.parse(signedUrl),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception('Upload logs a S3 falló: ${res.statusCode}');
    }
  }

  Future<String> _getSignedUrl({
    required String type,
    required String filename,
    required String date,
  }) async {
    final res = await http
        .post(
          Uri.parse(presignerUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': secret,
          },
          body: jsonEncode({'type': type, 'filename': filename, 'date': date}),
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('Presigner falló: ${res.statusCode}');
    }

    return jsonDecode(res.body)['url'] as String;
  }

  String _dateStr(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}
