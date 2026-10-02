import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// Caché en disco de las fotos de la nube (pestaña Cloud de la galería).
//
// Las URLs que devuelve la nube son URLs firmadas de S3: cambian en cada
// consulta (firma y fecha en el query string) aunque la foto sea la misma.
// Por eso la clave de la caché es la URL sin query (bucket + ruta del objeto):
// una foto ya descargada se muestra desde el teléfono aunque llegue con otra firma.
// Las fotos en S3 no cambian una vez subidas, así que no se revalidan.

/// Clave estable de una URL firmada de S3: la URL sin query ni fragmento.
String cloudImageCacheKey(String url) {
  final i = url.indexOf(RegExp(r'[?#]'));
  return i < 0 ? url : url.substring(0, i);
}

class CloudImageCache {
  CloudImageCache._();

  /// Lo mismo que dura una foto en la nube (lifecycle de S3: 365 días).
  static const stalePeriod = Duration(days: 365);
  static const maxFotos = 1500;

  static final CacheManager manager = CacheManager(Config(
    'brumaireFotosNube',
    stalePeriod: stalePeriod,
    maxNrOfCacheObjects: maxFotos,
    fileService: _FotoInmutableFileService(),
  ));

  /// Proveedor para el visor (misma clave que la miniatura: reutiliza el archivo).
  static ImageProvider provider(String url) => CachedNetworkImageProvider(
        url,
        cacheKey: cloudImageCacheKey(url),
        cacheManager: manager,
      );

  static Future<void> vaciar() => manager.emptyCache();
}

/// S3 no manda Cache-Control: sin esto la caché daría las fotos por vencidas
/// a los 7 días y las volvería a descargar. Las fotos no cambian, así que valen
/// lo mismo que su vida en la nube.
class _FotoInmutableFileService extends FileService {
  final _http = HttpFileService();

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async =>
      _Inmutable(await _http.get(url, headers: headers));
}

class _Inmutable implements FileServiceResponse {
  final FileServiceResponse _r;
  _Inmutable(this._r);

  @override
  Stream<List<int>> get content => _r.content;
  @override
  int? get contentLength => _r.contentLength;
  @override
  int get statusCode => _r.statusCode;
  @override
  DateTime get validTill => DateTime.now().add(CloudImageCache.stalePeriod);
  @override
  String? get eTag => _r.eTag;
  @override
  String get fileExtension => _r.fileExtension;
}
