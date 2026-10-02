import 'package:flutter/material.dart';
import '../models/fechas.dart';
import '../services/presigner_config.dart';
import '../services/cloud_gallery_service.dart';
import '../services/error_messages.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/truncated_notice.dart';

/// Pestaña Cloud: fotos ya subidas, desde una CloudGallerySource
/// ("Todas" vía POST /photos, por defecto, o "Aves" vía POST /gallery).
class CloudGalleryTab extends StatefulWidget {
  const CloudGalleryTab({super.key});

  @override
  State<CloudGalleryTab> createState() => _CloudGalleryTabState();
}

class _Section {
  final String title;
  final List<CloudPhoto> photos;
  const _Section(this.title, this.photos);
}

class _CloudGalleryTabState extends State<CloudGalleryTab>
    with AutomaticKeepAliveClientMixin {
  static const _ranges = ['Hoy', '7 días', '30 días'];

  int _rangeIdx = 1;
  int _sourceIdx = 0;
  List<CloudGallerySource> _sources = const [];
  bool _loading = false;
  String? _error;
  String? _errorDetail;
  List<CloudPhoto>? _photos;
  bool _truncated = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  DateTimeRange _dateRange() {
    final now = DateTime.now();
    return switch (_rangeIdx) {
      0 => DateTimeRange(
          start: DateTime(now.year, now.month, now.day),
          end:   DateTime(now.year, now.month, now.day, 23, 59, 59),
        ),
      2 => DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now),
      _ => DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
    };
  }

  Future<void> _fetch() async {
    setState(() { _loading = true; _error = null; _errorDetail = null; });
    try {
      final cfg    = await PresignerConfig.load();
      final url    = cfg.url;
      final secret = cfg.secret;
      if (!cfg.isComplete) {
        if (!mounted) return;
        setState(() {
          _error = 'Configura el servidor (Configuración ⚙ → «Presigner S3» en la pantalla principal).';
          _loading = false;
        });
        return;
      }
      _sources = cloudGallerySources(url, secret);
      if (_sourceIdx >= _sources.length) _sourceIdx = 0;
      final range = _dateRange();
      final page = await _sources[_sourceIdx].fetch(from: range.start, to: range.end);
      if (!mounted) return;
      setState(() { _photos = page.items; _truncated = page.truncated; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorMessages.cloud(e);
        _errorDetail = '$e';
        _loading = false;
      });
    }
  }

  CloudGallerySource? get _source => _sources.isEmpty ? null : _sources[_sourceIdx];

  List<_Section> _sections(List<CloudPhoto> photos) {
    final grouping = _source?.grouping ?? CloudGrouping.porDia;
    final map = <String, List<CloudPhoto>>{};
    final dayOf = <String, DateTime>{};
    for (final p in photos) {
      final String key;
      if (grouping == CloudGrouping.porEspecie) {
        key = _formatSpecies(p.species ?? 'sin especie');
      } else {
        final t = p.timestamp.toLocal();
        final d = DateTime(t.year, t.month, t.day);
        key = formatDayHeader(d);
        dayOf[key] = d;
      }
      map.putIfAbsent(key, () => []).add(p);
    }
    for (final list in map.values) {
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    }
    final keys = map.keys.toList();
    if (grouping == CloudGrouping.porEspecie) {
      // Especies con más detecciones primero.
      keys.sort((a, b) {
        final c = map[b]!.length.compareTo(map[a]!.length);
        return c != 0 ? c : a.compareTo(b);
      });
    } else {
      keys.sort((a, b) => dayOf[b]!.compareTo(dayOf[a]!));
    }
    return [for (final k in keys) _Section(k, map[k]!)];
  }

  static String _formatSpecies(String s) {
    final t = s.replaceAll('_', ' ').trim();
    if (t.isEmpty) return s;
    return t[0].toUpperCase() + t.substring(1);
  }

  void _open(_Section section, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(
          initialIndex: index,
          photos: [
            for (final p in section.photos)
              ViewerPhoto(
                image: p.displayUrl != null ? NetworkImage(p.displayUrl!) : null,
                title: '${formatDayHeader(p.timestamp.toLocal())} · '
                    '${formatTime(p.timestamp.toLocal())}',
                subtitle: p.species != null ? _formatSpecies(p.species!) : 'Sin aves detectadas',
                status: (text: 'En la nube', color: Colors.lightBlue.shade200, icon: Icons.cloud_done),
                details: [
                  for (final d in p.detections)
                    (
                      _formatSpecies(d.species),
                      '${(d.confidence * 100).toStringAsFixed(0)} %'
                          '${d.detectorScore != null ? ' (detector ${(d.detectorScore! * 100).toStringAsFixed(0)} %)' : ''}',
                    ),
                  if (p.imageUrl == null && p.rawUrl != null) ('Imagen', 'original (sin anotar)'),
                  ('Archivo', p.filename),
                ],
                sensors: p.env,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: List.generate(_ranges.length, (i) => ChoiceChip(
                        label: Text(_ranges[i]),
                        selected: i == _rangeIdx,
                        onSelected: _loading
                            ? null
                            : (_) {
                                setState(() => _rangeIdx = i);
                                _fetch();
                              },
                      )),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Actualizar',
                onPressed: _loading ? null : _fetch,
              ),
            ],
          ),
        ),
        if (_sources.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: SegmentedButton<int>(
              segments: [
                for (var i = 0; i < _sources.length; i++)
                  ButtonSegment(value: i, label: Text(_sources[i].label)),
              ],
              selected: {_sourceIdx},
              onSelectionChanged: (s) {
                setState(() => _sourceIdx = s.first);
                _fetch();
              },
            ),
          ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade700)),
              if (_errorDetail != null) ...[
                const SizedBox(height: 8),
                Text(_errorDetail!, textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
              ],
              const SizedBox(height: 16),
              FilledButton(onPressed: _fetch, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }
    final photos = _photos ?? const <CloudPhoto>[];
    if (photos.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Text(
                _source?.emptyMessage ?? 'Sin fotos en este período.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }

    final sections = _sections(photos);
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: sections.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            final src = _source?.label ?? '';
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$src: ${photos.length} ${photos.length == 1 ? 'foto' : 'fotos'} · ${_ranges[_rangeIdx]}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  if (_truncated) const TruncatedNotice(what: 'fotos'),
                ],
              ),
            );
          }
          final s = sections[i - 1];
          return _SectionBlock(section: s, onOpen: (idx) => _open(s, idx));
        },
      ),
    );
  }
}

class _SectionBlock extends StatelessWidget {
  final _Section section;
  final ValueChanged<int> onOpen;
  const _SectionBlock({required this.section, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final n = section.photos.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    section.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text(n == 1 ? '1 foto' : '$n fotos',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              ],
            ),
          ),
          GridView.count(
            crossAxisCount: 3,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < n; i++)
                _CloudThumb(photo: section.photos[i], onTap: () => onOpen(i)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CloudThumb extends StatelessWidget {
  final CloudPhoto photo;
  final VoidCallback onTap;
  const _CloudThumb({required this.photo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = photo.timestamp.toLocal();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (photo.displayUrl != null)
              Image.network(
                photo.displayUrl!,
                fit: BoxFit.cover,
                cacheWidth: 360,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : Container(color: Colors.grey.shade100),
                errorBuilder: (_, _, _) => Container(
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.broken_image, color: Colors.grey),
                ),
              )
            else
              Container(
                color: Colors.grey.shade200,
                child: const Icon(Icons.image_not_supported, color: Colors.grey),
              ),
            // Pie con fecha y confianza, legible sobre la foto.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(5, 10, 5, 3),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${t.day}/${t.month} ${formatTime(t).substring(0, 5)}',
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (photo.confidence != null)
                      Text(
                        '${(photo.confidence! * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
