import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

// Cliente HTTP del ESP32-CAM. Contrato: ~/Brumaire/.claude/contracts/esp32-http.md

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

/// Respuesta no-200 del ESP32 (el ESP32 respondió, así que está conectado).
class Esp32HttpException implements Exception {
  final String request; // p. ej. "GET /list"
  final int statusCode;
  final String body;
  const Esp32HttpException(this.request, this.statusCode, [this.body = '']);

  /// 500 "Failed to open Dir": la SD no responde.
  bool get isSdFailure => statusCode == 500 && body.contains('Failed to open Dir');

  /// 500 "SD Busy (503)": la SD estaba ocupada (transitorio).
  bool get isSdBusy => statusCode == 500 && body.contains('SD Busy');

  @override
  String toString() {
    final b = body.trim();
    return '$request falló: $statusCode${b.isEmpty ? '' : ' ($b)'}';
  }
}

/// Estado del ESP32 y de su SD según GET /list.
enum Esp32Status {
  conectado,
  sdNoResponde,
  sdOcupada,
  modoAp,
  noEncontrado;

  /// El ESP32 respondió (aunque la SD falle).
  bool get reachable => this != noEncontrado;
}

class Esp32Health {
  final Esp32Status status;

  /// Detalle técnico (código/cuerpo o excepción).
  final String? technical;
  const Esp32Health(this.status, [this.technical]);
}

enum RebootOutcome { ok, sdNoResponde, noVolvio, fallo }

class RebootResult {
  final RebootOutcome outcome;
  final String message;
  final String? technical;

  /// Último estado observado (para actualizar el banner).
  final Esp32Status status;
  const RebootResult(this.outcome, this.message, this.status, [this.technical]);
}

class Esp32Service {
  static const String defaultStaHost = 'esp32cam.local';
  static const String _apHost = '192.168.4.1';
  static const Duration _shortTimeout = Duration(seconds: 10);
  static const Duration _downloadTimeout = Duration(seconds: 60);

  final String staHost;
  final http.Client? client;

  Esp32Service({String? staHost, this.client}) : staHost = staHost ?? defaultStaHost;

  Uri _staUri(String path, [Map<String, String>? params]) =>
      Uri.http(staHost, path, params);

  Uri _apUri(String path) => Uri.http(_apHost, path);

  Future<http.Response> _get(Uri uri, Duration timeout) {
    final c = client;
    return (c != null ? c.get(uri) : http.get(uri)).timeout(timeout);
  }

  Future<http.Response> _post(Uri uri, Duration timeout,
      {Map<String, String>? headers, Object? body}) {
    final c = client;
    return (c != null
            ? c.post(uri, headers: headers, body: body)
            : http.post(uri, headers: headers, body: body))
        .timeout(timeout);
  }

  static void _check(http.Response res, String request) {
    if (res.statusCode != 200) throw Esp32HttpException(request, res.statusCode, res.body);
  }

  /// Clasifica una respuesta de GET /list según el contrato.
  static Esp32Status classifyList(int statusCode, String body) {
    if (statusCode == 200) return Esp32Status.conectado;
    final e = Esp32HttpException('GET /list', statusCode, body);
    if (e.isSdFailure) return Esp32Status.sdNoResponde;
    if (e.isSdBusy) return Esp32Status.sdOcupada;
    if (statusCode == 403) return Esp32Status.modoAp;
    // Otro error del servidor: el ESP32 respondió; se trata como SD con falla.
    return Esp32Status.sdNoResponde;
  }

  /// Estado del ESP32 y la SD (GET /list). No lanza excepciones.
  Future<Esp32Health> checkStatus({Duration timeout = _shortTimeout}) async {
    try {
      final res = await _get(_staUri('/list'), timeout);
      final status = classifyList(res.statusCode, res.body);
      return Esp32Health(
        status,
        status == Esp32Status.conectado
            ? null
            : '${Esp32HttpException('GET /list', res.statusCode, res.body)}',
      );
    } catch (e) {
      return Esp32Health(Esp32Status.noEncontrado, 'GET http://$staHost/list → $e');
    }
  }

  Future<bool> isReachable() async => (await checkStatus()).status.reachable;

  Future<List<Esp32FileInfo>> listFiles() async => (await listFilesPage()).files;

  /// GET /list con `count` y `truncated`. Lanza Esp32HttpException si no es 200.
  Future<Esp32FileList> listFilesPage() async {
    final res = await _get(_staUri('/list'), _shortTimeout);
    _check(res, 'GET /list');
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
    final res = await _get(_staUri('/download', {'file': filename}), _downloadTimeout);
    _check(res, 'GET /download');
    return res.bodyBytes;
  }

  /// Igual que downloadFile, pero devuelve null si el archivo no existe (404).
  /// Un 404 en log.txt es normal (log vacío tras /reset_log).
  Future<Uint8List?> tryDownloadFile(String filename) async {
    final res = await _get(_staUri('/download', {'file': filename}), _downloadTimeout);
    if (res.statusCode == 404) return null;
    _check(res, 'GET /download');
    return res.bodyBytes;
  }

  Future<void> deleteFile(String filename) async {
    final res = await _get(_staUri('/delete', {'file': filename}), _shortTimeout);
    _check(res, 'GET /delete');
  }

  Future<void> setTime(DateTime dt) async {
    final res = await _post(
      _staUri('/set_time'),
      _shortTimeout,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'ts': [dt.year - 2000, dt.month, dt.day, dt.hour, dt.minute, dt.second],
      }),
    );
    _check(res, 'POST /set_time');
  }

  Future<void> resetLog() async {
    final res = await _post(_staUri('/reset_log'), _shortTimeout);
    _check(res, 'POST /reset_log');
  }

  /// POST /reboot. Un 200 o la conexión cerrada por el ESP32 al reiniciarse
  /// cuentan como éxito; cualquier otra falla se lanza.
  Future<void> reboot() async {
    try {
      final res = await _post(_staUri('/reboot'), _shortTimeout);
      _check(res, 'POST /reboot');
    } on Esp32HttpException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } on http.ClientException catch (e) {
      if (!_isConnectionClosed(e.message)) rethrow;
    } on SocketException catch (e) {
      if (!_isConnectionClosed(e.message)) rethrow;
    }
  }

  static bool _isConnectionClosed(String msg) {
    final m = msg.toLowerCase();
    return m.contains('connection closed') ||
        m.contains('connection reset') ||
        m.contains('broken pipe');
  }

  /// Reinicia el ESP32 y espera a que vuelva, consultando GET /list cada
  /// `interval` hasta `timeout`. `onProgress` recibe mensajes para la UI.
  /// `delay` y `now` se inyectan en los tests.
  Future<RebootResult> rebootAndWait({
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 30),
    Duration initialWait = const Duration(seconds: 3),
    void Function(String message)? onProgress,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) async {
    final wait = delay ?? (d) => Future<void>.delayed(d);
    final clock = now ?? DateTime.now;

    onProgress?.call('Enviando la orden de reinicio…');
    try {
      await reboot();
    } catch (e) {
      final h = await checkStatus(timeout: const Duration(seconds: 5));
      return RebootResult(
        RebootOutcome.fallo,
        h.status.reachable
            ? 'El ESP32 no aceptó la orden de reinicio (¿firmware sin POST /reboot?). '
                'Usa el botón de reinicio de la placa.'
            : 'No se pudo enviar la orden: el ESP32 no está conectado.',
        h.status,
        '$e',
      );
    }

    final start = clock();
    // El ESP32 responde 200 y se reinicia ~0.5 s después: no consultar
    // enseguida para no confundir la instancia vieja con la nueva.
    await wait(initialWait);
    Esp32Health last = const Esp32Health(Esp32Status.noEncontrado);
    while (true) {
      final elapsed = clock().difference(start);
      onProgress?.call('Reiniciando… esperando que el ESP32 vuelva (${elapsed.inSeconds} s)');
      last = await checkStatus(timeout: const Duration(seconds: 3));
      switch (last.status) {
        case Esp32Status.conectado:
          return RebootResult(RebootOutcome.ok, 'ESP32 reiniciado, SD OK.', last.status);
        case Esp32Status.sdNoResponde:
          return RebootResult(
            RebootOutcome.sdNoResponde,
            'ESP32 reiniciado, pero la SD sigue sin responder: revisa la tarjeta o la alimentación.',
            last.status,
            last.technical,
          );
        case Esp32Status.sdOcupada:
        case Esp32Status.modoAp:
        case Esp32Status.noEncontrado:
          break; // seguir esperando
      }
      if (clock().difference(start) + interval > timeout) break;
      await wait(interval);
    }
    if (last.status == Esp32Status.sdOcupada) {
      return RebootResult(RebootOutcome.ok,
          'ESP32 reiniciado; la SD estaba ocupada, vuelve a verificar en un momento.', last.status);
    }
    return RebootResult(
      RebootOutcome.noVolvio,
      'El ESP32 no volvió a conectarse en ${timeout.inSeconds} s. Si quedó en modo '
      'configuración (red «ESP32_CONFIG_CAM»), vuelve a configurar el WiFi.',
      last.status,
      last.technical,
    );
  }

  // Enviar credenciales al ESP32 en modo AP (192.168.4.1)
  Future<void> configureWifi(String ssid, String password) async {
    final res = await _post(
      _apUri('/wifi'),
      _shortTimeout,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'ssid': ssid, 'password': password}),
    );
    _check(res, 'POST /wifi');
  }
}
