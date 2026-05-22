import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/log_entry.dart';

// Adapta los endpoints a los que exponga tu servidor.
// POST {baseUrl}/api/photos  → multipart: photo(file), filename, timestamp
// POST {baseUrl}/api/logs    → JSON: { "entries": [...] }
class BackendService {
  final String baseUrl;

  BackendService(this.baseUrl);

  Future<void> uploadPhoto(
    Uint8List bytes,
    String filename,
    DateTime timestamp,
  ) async {
    final uri = Uri.parse('$baseUrl/api/photos');
    final request = http.MultipartRequest('POST', uri)
      ..fields['filename'] = filename
      ..fields['timestamp'] = timestamp.toIso8601String()
      ..files.add(http.MultipartFile.fromBytes(
        'photo',
        bytes,
        filename: filename,
      ));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    if (streamed.statusCode != 200 && streamed.statusCode != 201) {
      throw Exception('Upload foto falló: ${streamed.statusCode}');
    }
  }

  Future<void> uploadLogs(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    final uri = Uri.parse('$baseUrl/api/logs');
    final res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'entries': entries.map((e) => e.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Upload logs falló: ${res.statusCode}');
    }
  }
}
