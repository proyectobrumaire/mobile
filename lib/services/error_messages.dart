import 'dart:async';
import 'dart:io';
import 'cloud_gallery_service.dart';
import 'esp32_service.dart';

/// Traduce excepciones técnicas a mensajes en lenguaje simple.
/// El detalle técnico (`'$e'`) se sigue mostrando aparte, oculto por defecto.
class ErrorMessages {
  ErrorMessages._();

  static int? _httpStatus(String text) {
    final m = RegExp(r'(?:falló|error)[:\s]+(\d{3})', caseSensitive: false).firstMatch(text);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  static bool _isNetwork(Object e) {
    if (e is TimeoutException || e is SocketException) return true;
    final t = '$e';
    return t.contains('ClientException') ||
        t.contains('SocketException') ||
        t.contains('Failed host lookup') ||
        t.contains('Connection refused') ||
        t.contains('Connection reset') ||
        t.contains('Network is unreachable');
  }

  /// Errores al hablar con el ESP32.
  static String esp32(Object e) {
    if (e is TimeoutException) {
      return 'El ESP32 no respondió a tiempo. Acércate a la estación o revisa la señal WiFi.';
    }
    if (_isNetwork(e)) {
      return 'Se perdió la conexión con el ESP32. Verifica que el teléfono siga en la misma red.';
    }
    if (e is Esp32HttpException) {
      if (e.isSdFailure) {
        return 'La tarjeta SD no responde: las fotos y eventos no se están guardando. '
            'Reinicia la placa (botón «Reiniciar» del aviso rojo o Configuración ⚙). Si persiste, '
            'revisa la tarjeta o la alimentación.';
      }
      if (e.isSdBusy) {
        return 'La SD estaba ocupada con otra operación. Intenta de nuevo en unos segundos.';
      }
    }
    final t = '$e';
    final code = _httpStatus(t);
    if (code == 404) return 'El archivo ya no está en la SD.';
    if (code == 403) return 'El ESP32 no está en modo estación (conectado al WiFi).';
    if (code != null && code >= 500) {
      return 'El ESP32 no pudo leer la SD (puede estar ocupada). Intenta de nuevo en unos segundos.';
    }
    if (e is FileSystemException) {
      return 'No se pudo guardar el archivo en el teléfono (¿poco espacio?).';
    }
    if (e is FormatException) return 'El ESP32 respondió algo inesperado.';
    return 'Ocurrió un error inesperado con el ESP32.';
  }

  /// Errores al subir al presigner / S3.
  static String backend(Object e) {
    if (e is TimeoutException) {
      return 'El servidor tardó demasiado en responder. Revisa la conexión a internet.';
    }
    if (_isNetwork(e)) {
      return 'Sin conexión a internet o el servidor no responde.';
    }
    if (e is FileSystemException) {
      return 'No se encontró la foto en el teléfono.';
    }
    final t = '$e';
    final code = _httpStatus(t);
    if (t.contains('Presigner')) {
      if (code == 401 || code == 403) {
        return 'El servidor rechazó la clave. Revisa el secret del presigner.';
      }
      if (code == 404) return 'La URL del presigner no es correcta.';
      return 'El servidor no pudo preparar la subida.';
    }
    if (code == 403) {
      return 'S3 rechazó la subida (la URL firmada pudo haber vencido).';
    }
    return 'Ocurrió un error inesperado al subir.';
  }

  /// Errores al consultar la nube (POST /gallery, /photos, /events).
  static String cloud(Object e) {
    if (e is TimeoutException) {
      return 'El servidor tardó demasiado en responder. Revisa la conexión a internet.';
    }
    if (_isNetwork(e)) return 'Sin conexión a internet o el servidor no responde.';
    if (e is CloudApiException) {
      return switch (e.statusCode) {
        401 || 403 => 'El servidor rechazó la clave. Revisa el secret del presigner.',
        404 => 'El servidor todavía no ofrece esta consulta (¿falta desplegar la nube?).',
        400 => 'El servidor no entendió la consulta.',
        _ => 'El servidor tuvo un problema (${e.statusCode}). Intenta más tarde.',
      };
    }
    if (e is FormatException || e is TypeError) {
      return 'El servidor respondió en un formato inesperado.';
    }
    return 'No se pudo consultar la nube.';
  }
}
