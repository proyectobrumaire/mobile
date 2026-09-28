import 'package:flutter/material.dart';
import 'sensor_grid.dart';

/// Foto para el visor, independiente de si es local o de la nube.
class ViewerPhoto {
  /// null: la foto no tiene imagen disponible (se muestra un ícono).
  final ImageProvider? image;
  final String title;
  final String? subtitle;

  /// Etiqueta de estado (p. ej. "Pendiente de subir") con su color.
  final ({String text, Color color, IconData icon})? status;

  /// Datos extra en pares etiqueta → valor (p. ej. confianza de la especie).
  final List<(String, String)> details;
  final Map<String, double> sensors;

  const ViewerPhoto({
    required this.image,
    required this.title,
    this.subtitle,
    this.status,
    this.details = const [],
    this.sensors = const {},
  });
}

/// Visor a pantalla completa: deslizar entre fotos, zoom con pellizco o doble
/// toque, y panel con los datos (sensores) de la foto actual.
class PhotoViewerScreen extends StatefulWidget {
  final List<ViewerPhoto> photos;
  final int initialIndex;

  /// Si se da, aparece el botón de borrar. Devuelve true si se borró.
  final Future<bool> Function(BuildContext context, int index)? onDelete;

  const PhotoViewerScreen({
    super.key,
    required this.photos,
    this.initialIndex = 0,
    this.onDelete,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final List<ViewerPhoto> _photos = List.of(widget.photos);
  late int _index =
      _photos.isEmpty ? 0 : widget.initialIndex.clamp(0, _photos.length - 1);
  late final PageController _ctrl = PageController(initialPage: _index);
  bool _zoomed = false;
  bool _showInfo = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    if (onDelete == null) return;
    final deleted = await onDelete(context, _index);
    if (!deleted || !mounted) return;
    setState(() {
      _photos.removeAt(_index);
      if (_index >= _photos.length) _index = _photos.length - 1;
      _zoomed = false;
    });
    if (_photos.isEmpty) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_photos.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final photo = _photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${_photos.length}'),
        actions: [
          IconButton(
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            tooltip: _showInfo ? 'Ocultar datos' : 'Ver datos',
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
          if (widget.onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Borrar foto',
              onPressed: _delete,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _ctrl,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _photos.length,
              onPageChanged: (i) => setState(() {
                _index = i;
                _zoomed = false;
              }),
              itemBuilder: (_, i) => _ZoomableImage(
                key: ObjectKey(_photos[i]),
                image: _photos[i].image,
                onZoomChanged: (z) {
                  if (z != _zoomed) setState(() => _zoomed = z);
                },
              ),
            ),
          ),
          if (_showInfo)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.42,
              ),
              child: _InfoPanel(photo: photo),
            ),
        ],
      ),
    );
  }
}

class _ZoomableImage extends StatefulWidget {
  final ImageProvider? image;
  final ValueChanged<bool> onZoomChanged;
  const _ZoomableImage({super.key, required this.image, required this.onZoomChanged});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _ctrl = TransformationController();
  Offset _tapPos = Offset.zero;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _isZoomed => _ctrl.value.getMaxScaleOnAxis() > 1.01;

  void _toggleZoom() {
    if (_isZoomed) {
      _ctrl.value = Matrix4.identity();
      widget.onZoomChanged(false);
    } else {
      const s = 2.5;
      _ctrl.value = Matrix4.diagonal3Values(s, s, 1)
        ..setTranslationRaw(-_tapPos.dx * (s - 1), -_tapPos.dy * (s - 1), 0);
      widget.onZoomChanged(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    if (image == null) {
      return const Center(
        child: Icon(Icons.image_not_supported, color: Colors.white54, size: 64),
      );
    }
    return GestureDetector(
      onDoubleTapDown: (d) => _tapPos = d.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _ctrl,
        minScale: 1,
        maxScale: 6,
        onInteractionEnd: (_) => widget.onZoomChanged(_isZoomed),
        child: SizedBox.expand(
          child: Image(
            image: image,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator(color: Colors.white54)),
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final ViewerPhoto photo;
  const _InfoPanel({required this.photo});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = photo.status;
    return Material(
      color: const Color(0xFF1C1C1E),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(photo.title,
                        style: text.titleSmall?.copyWith(color: Colors.white)),
                  ),
                  if (status != null)
                    Chip(
                      avatar: Icon(status.icon, size: 16, color: status.color),
                      label: Text(status.text),
                      labelStyle: TextStyle(color: status.color, fontSize: 12),
                      backgroundColor: status.color.withValues(alpha: 0.12),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              if (photo.subtitle != null)
                Text(photo.subtitle!,
                    style: text.bodySmall?.copyWith(color: Colors.white70)),
              for (final (label, value) in photo.details)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: '$label: ', style: const TextStyle(color: Colors.white60)),
                      TextSpan(
                        text: value,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    style: text.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              if (photo.sensors.isEmpty)
                Text(
                  'Sin lecturas de sensores para este instante.',
                  style: text.bodySmall?.copyWith(color: Colors.white54),
                )
              else
                SensorGrid(
                  sensors: photo.sensors,
                  labelColor: Colors.white60,
                  valueColor: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
