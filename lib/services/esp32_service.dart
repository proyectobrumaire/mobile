import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class Esp32FileInfo {
  final String name;
  final int size;
  const Esp32FileInfo({required this.name, required this.size});
}

/// Respuesta completa de GET /list. El ESP32 devuelve máx. 20 archivos;
/// `truncated` indica que en la SD quedan más.
class Esp32FileList {
  final List<Esp32FileInfo> files;
  final int count;
  final bool truncated;
  const Esp32FileList({
    required this.files,
    required this.count,
    required this.truncated,
  });
}

class Esp32Service {
  static const String defaultStaHost = 'esp32cam.local';
  static const String _apHost = '192.168.4.1';
  static const Duration _shortTimeout = Duration(seconds: 10);
  static const Duration _downloadTimeout = Duration(seconds: 60);

  final String staHost;

  Esp32Service({String? staHost}) : staHost = staHost ?? defaultStaHost;

  Uri _staUri(String path, [Map<String, String>? params]) =>
      Uri.http(staHost, path, params);

  Uri _apUri(String path) => Uri.http(_apHost, path);

  Future<bool> isReachable() async {
    try {
      await ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Como isReachable, pero lanza la excepción para poder mostrar el detalle.
  Future<void> ping() async {
    final res = await http.get(_staUri('/list')).timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('GET /list falló: ${res.statusCode}');
    }
  }

  Future<List<Esp32FileInfo>> listFiles() async => (await listFilesPage()).files;

  /// GET /list con `count` y `truncated`.
  Future<Esp32FileList> listFilesPage() async {
    final res = await http.get(_staUri('/list')).timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('GET /list falló: ${res.statusCode}');
    }
    return parseList(res.body);
  }

  static Esp32FileList parseList(String body) {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>)
        .map((f) => Esp32FileInfo(
              name: f['name'] as String,
              size: (f['size'] as num).toInt(),
            ))
        .toList();
    return Esp32FileList(
      files: files,
      count: (data['count'] as num?)?.toInt() ?? files.length,
      truncated: data['truncated'] == true,
    );
  }

  Future<Uint8List> downloadFile(String filename) async {
    final res = await http
        .get(_staUri('/download', {'file': filename}))
        .timeout(_downloadTimeout);
    if (res.statusCode != 200) {
      throw Exception('GET /download falló: ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  // Igual que downloadFile, pero devuelve null si el archivo no existe (404)
  Future<Uint8List?> tryDownloadFile(String filename) async {
    final res = await http
        .get(_staUri('/download', {'file': filename}))
        .timeout(_downloadTimeout);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw Exception('GET /download falló: ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  Future<void> deleteFile(String filename) async {
    final res = await http
        .get(_staUri('/delete', {'file': filename}))
        .timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('GET /delete falló: ${res.statusCode}');
    }
  }

  Future<void> setTime(DateTime dt) async {
    final res = await http
        .post(
          _staUri('/set_time'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'ts': [
              dt.year - 2000,
              dt.month,
              dt.day,
              dt.hour,
              dt.minute,
              dt.second,
            ],
          }),
        )
        .timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('POST /set_time falló: ${res.statusCode}');
    }
  }

  Future<void> resetLog() async {
    final res = await http
        .post(_staUri('/reset_log'))
        .timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('POST /reset_log falló: ${res.statusCode}');
    }
  }

  // Enviar credenciales al ESP32 en modo AP (192.168.4.1)
  Future<void> configureWifi(String ssid, String password) async {
    final res = await http
        .post(
          _apUri('/wifi'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'ssid': ssid, 'password': password}),
        )
        .timeout(_shortTimeout);
    if (res.statusCode != 200) {
      throw Exception('POST /wifi falló: ${res.statusCode}');
    }
  }
}
