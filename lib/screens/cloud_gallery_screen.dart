import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/log_entry.dart';
import '../services/cloud_gallery_service.dart';

class CloudGalleryScreen extends StatefulWidget {
  const CloudGalleryScreen({super.key});

  @override
  State<CloudGalleryScreen> createState() => _CloudGalleryScreenState();
}

class _CloudGalleryScreenState extends State<CloudGalleryScreen> {
  static const _ranges = ['Hoy', '7 días', '30 días'];

  int _rangeIdx = 1;
  bool _loading = false;
  String? _error;
  Map<String, List<CloudDetection>>? _data;

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
      2 => DateTimeRange(
          start: now.subtract(const Duration(days: 30)),
          end:   now,
        ),
      _ => DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end:   now,
        ),
    };
  }

  Future<void> _fetch() async {
    setState(() { _loading = true; _error = null; });
    try {
      final prefs  = await SharedPreferences.getInstance();
      final url    = prefs.getString('presigner_url') ?? '';
      final secret = prefs.getString('presigner_secret') ?? '';
      if (url.isEmpty || secret.isEmpty) {
        setState(() { _error = 'Configura el presigner en la pantalla principal.'; _loading = false; });
        return;
      }
      final range = _dateRange();
      final data  = await CloudGalleryService(url, secret).fetch(
        from: range.start,
        to:   range.end,
      );
      setState(() { _data = data; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  int get _totalDetections =>
      _data?.values.fold<int>(0, (s, list) => s + list.length) ?? 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_loading || _data == null
            ? 'Galería Cloud'
            : 'Galería Cloud ($_totalDetections)'),
        actions: [
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _fetch,
            ),
        ],
      ),
      body: Column(
        children: [
          // Range selector
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: List.generate(_ranges.length, (i) {
                final selected = i == _rangeIdx;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_ranges[i]),
                    selected: selected,
                    onSelected: (_) {
                      setState(() => _rangeIdx = i);
                      _fetch();
                    },
                  ),
                );
              }),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
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
              const SizedBox(height: 16),
              FilledButton(onPressed: _fetch, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }
    if (_data == null || _data!.isEmpty) {
      return const Center(
        child: Text(
          'Sin detecciones en este período.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final species = _data!.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: species.length,
      itemBuilder: (_, i) => _SpeciesSection(
        species: species[i],
        detections: _data![species[i]]!,
      ),
    );
  }
}

// ─── Sección por especie ──────────────────────────────────────────────────────

class _SpeciesSection extends StatelessWidget {
  final String species;
  final List<CloudDetection> detections;
  const _SpeciesSection({required this.species, required this.detections});

  String _formatSpecies(String s) {
    final parts = s.replaceAll('_', ' ').split(' ');
    if (parts.isEmpty) return s;
    parts[0] = parts[0][0].toUpperCase() + parts[0].substring(1);
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              const Icon(Icons.flutter_dash, size: 18, color: Colors.green),
              const SizedBox(width: 6),
              Text(
                _formatSpecies(species),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(${detections.length})',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            ],
          ),
        ),
        ...detections.map((d) => _DetectionCard(detection: d)),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ─── Card de detección ────────────────────────────────────────────────────────

class _DetectionCard extends StatelessWidget {
  final CloudDetection detection;
  const _DetectionCard({required this.detection});

  String _fmtTs(DateTime dt) {
    final d = dt.toLocal();
    return '${d.year}-${_p(d.month)}-${_p(d.day)}  ${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';
  }

  String _p(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Imagen anotada
          SizedBox(
            height: 180,
            width: double.infinity,
            child: detection.imageUrl != null
                ? GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _ImageViewer(url: detection.imageUrl!),
                      ),
                    ),
                    child: Image.network(
                      detection.imageUrl!,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : Container(
                              color: Colors.grey.shade100,
                              child: const Center(
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                      errorBuilder: (ctx, e, st) => Container(
                        color: Colors.grey.shade200,
                        child: const Center(
                          child: Icon(Icons.broken_image, color: Colors.grey, size: 40),
                        ),
                      ),
                    ),
                  )
                : Container(
                    color: Colors.grey.shade100,
                    child: const Center(
                      child: Icon(Icons.image_not_supported, color: Colors.grey, size: 40),
                    ),
                  ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _fmtTs(detection.timestamp),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                _Pill(
                  label: '${(detection.confidence * 100).toStringAsFixed(0)}%',
                  color: Colors.green.shade700,
                ),
                const SizedBox(width: 6),
                _Pill(
                  label: 'det ${(detection.detectorScore * 100).toStringAsFixed(0)}%',
                  color: Colors.blue.shade700,
                ),
              ],
            ),
          ),

          if (detection.env.isNotEmpty) ...[
            const Divider(height: 18, indent: 12, endIndent: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _EnvRow(env: detection.env),
            ),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─── Fila de sensores ─────────────────────────────────────────────────────────

class _EnvRow extends StatelessWidget {
  final Map<String, double> env;
  const _EnvRow({required this.env});

  static const _order = ['T1_K', 'H1_K', 'P1_K', 'P2_K', 'W1_K', 'H2_K'];

  @override
  Widget build(BuildContext context) {
    final keys = [
      ..._order.where(env.containsKey),
      ...env.keys.where((k) => !_order.contains(k)),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: keys.map((k) {
        final label = sensorLabels[k] ?? k;
        final val   = env[k]!;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 3),
            Text(val.toStringAsFixed(1),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        );
      }).toList(),
    );
  }
}

// ─── Visor de imagen a pantalla completa ─────────────────────────────────────

class _ImageViewer extends StatelessWidget {
  final String url;
  const _ImageViewer({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(
            url,
            errorBuilder: (ctx, e, st) => const Icon(
              Icons.broken_image,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    );
  }
}
