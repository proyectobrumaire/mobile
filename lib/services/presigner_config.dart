import 'package:shared_preferences/shared_preferences.dart';

/// Configuración del presigner (URL de API Gateway + secret `x-api-key`).
///
/// Prioridad, campo por campo: lo guardado en SharedPreferences (si no está
/// vacío) y, si no, el valor compilado en el APK con
/// `--dart-define=PRESIGNER_URL=... --dart-define=PRESIGNER_SECRET=...`
/// (ver scripts/build_apk.sh). Los valores compilados nunca se escriben en el
/// repo ni en SharedPreferences.
class PresignerConfig {
  static const keyUrl = 'presigner_url';
  static const keySecret = 'presigner_secret';

  static const buildUrl = String.fromEnvironment('PRESIGNER_URL');
  static const buildSecret = String.fromEnvironment('PRESIGNER_SECRET');

  final String url;
  final String secret;
  final bool urlFromBuild;
  final bool secretFromBuild;

  /// Lo que hay guardado (para prellenar el diálogo; nunca el compilado).
  final String savedUrl;
  final String savedSecret;

  /// Hay valores compilados disponibles (aunque no se estén usando).
  final bool hasBuildDefaults;

  const PresignerConfig._({
    required this.url,
    required this.secret,
    required this.urlFromBuild,
    required this.secretFromBuild,
    required this.savedUrl,
    required this.savedSecret,
    required this.hasBuildDefaults,
  });

  bool get isComplete => url.isNotEmpty && secret.isNotEmpty;

  /// Algún campo en uso viene de la configuración incluida en la app.
  bool get usingBuildDefaults => urlFromBuild || secretFromBuild;

  /// Regla de prioridad (pura, para tests).
  static PresignerConfig resolve({
    String? savedUrl,
    String? savedSecret,
    String buildUrl = buildUrl,
    String buildSecret = buildSecret,
  }) {
    final su = (savedUrl ?? '').trim();
    final ss = (savedSecret ?? '').trim();
    final bu = buildUrl.trim();
    final bs = buildSecret.trim();
    return PresignerConfig._(
      url: su.isNotEmpty ? su : bu,
      secret: ss.isNotEmpty ? ss : bs,
      urlFromBuild: su.isEmpty && bu.isNotEmpty,
      secretFromBuild: ss.isEmpty && bs.isNotEmpty,
      savedUrl: su,
      savedSecret: ss,
      hasBuildDefaults: bu.isNotEmpty || bs.isNotEmpty,
    );
  }

  static Future<PresignerConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return resolve(
      savedUrl: prefs.getString(keyUrl),
      savedSecret: prefs.getString(keySecret),
    );
  }

  /// Guarda solo los campos no vacíos (un campo vacío deja el valor actual).
  static Future<void> save({required String url, required String secret}) async {
    final prefs = await SharedPreferences.getInstance();
    if (url.trim().isNotEmpty) await prefs.setString(keyUrl, url.trim());
    if (secret.trim().isNotEmpty) await prefs.setString(keySecret, secret.trim());
  }

  /// Borra lo guardado: se vuelve a la configuración incluida en la app.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyUrl);
    await prefs.remove(keySecret);
  }
}
