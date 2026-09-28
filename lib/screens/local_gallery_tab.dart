import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/fechas.dart';
import '../models/gallery_group.dart';
import '../models/sync_progress.dart';
import '../services/backend_service.dart';
import '../services/backend_sync_service.dart';
import '../services/local_storage_service.dart';
import '../services/sync_run_controller.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/sync_progress_view.dart';

/// Nombre legible del evento del log.
String eventLabel(String? event) => switch (event) {
      'BIRD' => 'Ave detectada',
      null => 'Sin evento registrado',
      _ => event,
    };

/// Pestaña Local: fotos que están en el teléfono (pendientes de subir), por
/// día y evento, con subida al servidor y borrado manual.
class LocalGalleryTab extends StatefulWidget {
  const LocalGalleryTab({super.key});

  @override
  State<LocalGalleryTab> createState() => _LocalGalleryTabState();
}

sealed class _Item {}

class _DayItem extends _Item {
  final GalleryDay day;
  _DayItem(this.day);
}

class _EventItem extends _Item {
  final GalleryGroup group;
  _EventItem(this.group);
}

class _LocalGalleryTabState extends State<LocalGalleryTab>
    with AutomaticKeepAliveClientMixin {
  final _storage = LocalStorageService();
  final _sync = SyncRunController.instance;

  List<GalleryDay>? _days;
  PendingCounts? _pending;
  String? _loadError;
  int _seenRuns = 0;

  /// Ids de fotos seleccionadas (modo selección para borrar).
  final _selected = <int>{};
  bool get _selecting => _selected.isNotEmpty;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _seenRuns = _sync.finishedRuns;
    _sync.addListener(_onSyncChanged);
    _load();
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    if (!mounted) return;
    if (_sync.finishedRuns != _seenRuns) {
      _seenRuns = _sync.finishedRuns;
      _load();
    }
    setState(() {});
  }

  Future<void> _load() async {
    try {
      final photos = await _storage.allPhotos();
      final times = photos.map(photoDateTime).whereType<DateTime>();
      final entries = await _storage.logEntriesAt(times);
      final pending = await _storage.pendingCounts();
      if (!mounted) return;
      setState(() {
        _days = buildGalleryDays(photos, entries);
        _pending = pending;
        _loadError = null;
        final ids = photos.map((p) => p.id).toSet();
        _selected.removeWhere((id) => !ids.contains(id));
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  // ─── Subida ────────────────────────────────────────────────────────────────

  Future<void> _upload() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('presigner_url') ?? '';
    final secret = prefs.getString('presigner_secret') ?? '';
    if (!mounted) return;
    if (url.isEmpty || secret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Primero configura el servidor (ícono «Presigner S3» en la pantalla principal).'),
      ));
      return;
    }
    _sync.start(
      SyncKind.subida,
      (isCancelled) => BackendSyncService(BackendService(url, secret), _storage)
          .sync(isCancelled: isCancelled),
    );
  }

  // ─── Borrado ───────────────────────────────────────────────────────────────

  List<StoredPhoto> get _allPhotos => [
        for (final d in _days ?? const <GalleryDay>[])
          for (final g in d.groups) ...g.photos,
      ];

  Future<bool> _confirmAndDelete(List<StoredPhoto> photos) async {
    if (photos.isEmpty) return false;
    if (_sync.running) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Espera a que termine la sincronización en curso para borrar.'),
      ));
      return false;
    }
    final notUploaded = photos.where((p) => !p.uploaded).length;
    final n = photos.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_forever, color: Theme.of(ctx).colorScheme.error),
        title: Text(n == 1 ? '¿Borrar esta foto?' : '¿Borrar $n fotos?'),
        content: Text(
          notUploaded > 0
              ? '${notUploaded == n ? (n == 1 ? 'Esta foto aún NO se ha subido' : 'Estas fotos aún NO se han subido') : '$notUploaded de ellas aún NO se han subido'} '
                  'a la nube. Si las borras se perderán definitivamente.\n\n'
                  'Sus lecturas de sensores se conservan hasta subirse.'
              : 'Ya están en la nube; solo se borran del teléfono.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await _storage.deletePhotos(photos);
    await _storage.purgeUploadedLogEntries();
    if (!mounted) return true;
    setState(() => _selected.removeAll(photos.map((p) => p.id)));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 1 ? 'Foto borrada.' : '$n fotos borradas.'),
    ));
    await _load();
    return true;
  }

  void _toggle(StoredPhoto p) => setState(() {
        if (!_selected.remove(p.id)) _selected.add(p.id);
      });

  void _toggleGroup(GalleryGroup g) => setState(() {
        final all = g.photos.every((p) => _selected.contains(p.id));
        for (final p in g.photos) {
          all ? _selected.remove(p.id) : _selected.add(p.id);
        }
      });

  // ─── Visor ─────────────────────────────────────────────────────────────────

  Future<void> _openViewer(StoredPhoto photo) async {
    final photos = <StoredPhoto>[];
    final items = <ViewerPhoto>[];
    for (final d in _days!) {
      for (final g in d.groups) {
        for (var i = 0; i < g.photos.length; i++) {
          final p = g.photos[i];
          photos.add(p);
          items.add(ViewerPhoto(
            image: FileImage(File(p.localPath)),
            title: g.timestamp != null
                ? '${formatDayHeader(g.timestamp!)} · ${formatTime(g.timestamp!)}'
                : p.filename,
            subtitle: '${eventLabel(g.eventType)} · foto ${i + 1} de ${g.photos.length}',
            status: p.uploaded
                ? (text: 'Ya subida', color: Colors.green.shade400, icon: Icons.cloud_done)
                : (text: 'Pendiente de subir', color: Colors.orange.shade300, icon: Icons.cloud_upload_outlined),
            sensors: g.sensors,
          ));
        }
      }
    }
    final index = photos.indexWhere((p) => p.id == photo.id);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(
          photos: items,
          initialIndex: index < 0 ? 0 : index,
          onDelete: (ctx, i) async {
            final target = photos[i];
            final deleted = await _confirmAndDelete([target]);
            if (deleted) photos.removeAt(i);
            return deleted;
          },
        ),
      ),
    );
    await _load();
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Column(
        children: [
          _selecting ? _selectionBar() : _uploadBar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _uploadBar() {
    final photos = _pending?.photos ?? 0;
    final lines = _pending?.logLines ?? 0;
    final nothing = photos == 0 && lines == 0;
    final busy = _sync.running;
    final downloading = busy && _sync.state?.kind == SyncKind.descarga;
    final parts = [
      if (photos > 0) '$photos ${photos == 1 ? 'foto' : 'fotos'}',
      if (lines > 0) '$lines ${lines == 1 ? 'lectura' : 'lecturas'}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: nothing || busy ? null : _upload,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(nothing
                ? 'Todo está subido'
                : 'Subir al servidor (${parts.join(', ')})'),
          ),
          const SizedBox(height: 4),
          Text(
            downloading
                ? 'Hay una descarga de la SD en curso; espera a que termine para subir.'
                : 'Al subirse, las fotos y lecturas se borran del teléfono.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Salir de la selección',
            onPressed: () => setState(_selected.clear),
          ),
          Expanded(
            child: Text(
              _selected.length == 1 ? '1 seleccionada' : '${_selected.length} seleccionadas',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _selected.addAll(_allPhotos.map((p) => p.id))),
            child: const Text('Todas'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () => _confirmAndDelete(
              _allPhotos.where((p) => _selected.contains(p.id)).toList(),
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Borrar'),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return Center(child: Text('No se pudo leer la galería:\n$_loadError', textAlign: TextAlign.center));
    }
    if (_days == null) return const Center(child: CircularProgressIndicator());

    final state = _sync.state;
    final showRun = state != null && state.kind == SyncKind.subida;
    final items = <_Item>[
      for (final d in _days!) ...[_DayItem(d), ...d.groups.map(_EventItem.new)],
    ];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              children: [
                if (showRun)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: SyncProgressView(
                      state: state,
                      cancelRequested: _sync.cancelRequested,
                      onCancel: _sync.cancel,
                      onClose: _sync.clear,
                    ),
                  ),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 64, 24, 0),
                    child: Text(
                      'No hay fotos en el teléfono.\n'
                      'Descarga la SD desde la pantalla principal; las fotos que ya '
                      'se subieron están en la pestaña Cloud.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
            );
          }
          return switch (items[i - 1]) {
            _DayItem(:final day) => _DayHeader(day: day),
            _EventItem(:final group) => _EventBlock(
                group: group,
                selecting: _selecting,
                selected: _selected,
                onTapPhoto: (p) => _selecting ? _toggle(p) : _openViewer(p),
                onLongPressPhoto: _toggle,
                onToggleGroup: () => _toggleGroup(group),
                onDeleteGroup: () => _confirmAndDelete(group.photos),
              ),
          };
        },
      ),
    );
  }
}

// ─── Widgets ──────────────────────────────────────────────────────────────────

class _DayHeader extends StatelessWidget {
  final GalleryDay day;
  const _DayHeader({required this.day});

  @override
  Widget build(BuildContext context) {
    final n = day.photoCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Text(
            day.date != null ? formatDayHeader(day.date!) : 'Sin fecha',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Text(
            n == 1 ? '1 foto' : '$n fotos',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _EventBlock extends StatelessWidget {
  final GalleryGroup group;
  final bool selecting;
  final Set<int> selected;
  final ValueChanged<StoredPhoto> onTapPhoto;
  final ValueChanged<StoredPhoto> onLongPressPhoto;
  final VoidCallback onToggleGroup;
  final VoidCallback onDeleteGroup;

  const _EventBlock({
    required this.group,
    required this.selecting,
    required this.selected,
    required this.onTapPhoto,
    required this.onLongPressPhoto,
    required this.onToggleGroup,
    required this.onDeleteGroup,
  });

  @override
  Widget build(BuildContext context) {
    final ts = group.timestamp;
    final nSel = group.photos.where((p) => selected.contains(p.id)).length;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 4),
              Text(
                ts != null ? formatTime(ts) : group.timestampRaw,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              // Expanded (sin Spacer al lado) para que la etiqueta use todo el
              // ancho libre; si no cabe, pasa a una segunda línea.
              Expanded(
                child: Text(
                  eventLabel(group.eventType) +
                      (group.hasSensorData ? '' : ' · sin lecturas'),
                  style: text.bodySmall?.copyWith(
                    color: group.eventType == 'BIRD' ? Colors.green.shade700 : Colors.grey.shade600,
                  ),
                  softWrap: true,
                ),
              ),
              if (selecting)
                Checkbox(
                  tristate: true,
                  value: nSel == 0 ? false : (nSel == group.photos.length ? true : null),
                  onChanged: (_) => onToggleGroup(),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Opciones del evento',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) {
                    if (v == 'borrar') onDeleteGroup();
                    if (v == 'seleccionar') onToggleGroup();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'seleccionar',
                      child: ListTile(
                        leading: Icon(Icons.check_box_outlined),
                        title: Text('Seleccionar evento'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'borrar',
                      child: ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(group.photos.length == 1
                            ? 'Borrar la foto'
                            : 'Borrar el evento (${group.photos.length} fotos)'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          GridView.count(
            crossAxisCount: 3,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final p in group.photos)
                _Thumb(
                  photo: p,
                  selecting: selecting,
                  selected: selected.contains(p.id),
                  onTap: () => onTapPhoto(p),
                  onLongPress: () => onLongPressPhoto(p),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final StoredPhoto photo;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _Thumb({
    required this.photo,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(photo.localPath),
              fit: BoxFit.cover,
              cacheWidth: 360, // miniatura: no decodificar la foto completa
              errorBuilder: (_, _, _) => Container(
                color: Colors.grey.shade200,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
            if (selected) Container(color: scheme.primary.withValues(alpha: 0.35)),
            Positioned(
              right: 4,
              bottom: 4,
              child: _Badge(
                icon: photo.uploaded ? Icons.cloud_done : Icons.cloud_upload_outlined,
                color: photo.uploaded ? Colors.green.shade600 : Colors.orange.shade700,
                tooltip: photo.uploaded ? 'Ya subida a la nube' : 'Pendiente de subir',
              ),
            ),
            if (selecting)
              Positioned(
                left: 4,
                top: 4,
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? scheme.primary : Colors.white,
                  shadows: const [Shadow(blurRadius: 4)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  const _Badge({required this.icon, required this.color, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}
