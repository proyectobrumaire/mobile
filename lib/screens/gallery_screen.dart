import 'dart:io';
import 'package:flutter/material.dart';
import '../models/gallery_group.dart';
import '../models/log_entry.dart';
import '../services/local_storage_service.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _storage = LocalStorageService();
  List<GalleryGroup>? _groups;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photos = await _storage.allPhotos();
    final entries = await _storage.allLogEntries();

    // Agrupar fotos por timestamp raw
    final Map<String, List<StoredPhoto>> photosByTs = {};
    for (final p in photos) {
      final key = p.timestamp ?? '__sin_ts__';
      photosByTs.putIfAbsent(key, () => []).add(p);
    }

    // Agrupar log entries por DateTime
    final Map<DateTime, List<LogEntry>> entriesByTs = {};
    for (final e in entries) {
      entriesByTs.putIfAbsent(e.timestamp, () => []).add(e);
    }

    final groups = photosByTs.entries.map((entry) {
      final ts = entry.key;
      final parsedTs = _parsePhotoTs(ts);
      final matchingEntries = parsedTs != null ? (entriesByTs[parsedTs] ?? []) : [];

      final eventEntry = matchingEntries
          .where((e) => e.type == EntryType.event)
          .firstOrNull;

      final sensors = <String, double>{};
      for (final e in matchingEntries.where((e) => e.type == EntryType.sensorData)) {
        if (e.sensorKey != null && e.sensorValue != null) {
          sensors[e.sensorKey!] = e.sensorValue!;
        }
      }

      return GalleryGroup(
        timestampRaw: ts,
        timestamp: parsedTs,
        photos: entry.value..sort((a, b) => a.filename.compareTo(b.filename)),
        eventType: eventEntry?.event,
        sensors: sensors,
      );
    }).toList();

    groups.sort((a, b) {
      if (a.timestamp == null) return 1;
      if (b.timestamp == null) return -1;
      return b.timestamp!.compareTo(a.timestamp!);
    });

    if (mounted) setState(() => _groups = groups);
  }

  DateTime? _parsePhotoTs(String ts) {
    try {
      final sides = ts.split('T');
      if (sides.length != 2) return null;
      final d = sides[0].split('-');
      final t = sides[1].split('-');
      if (d.length != 3 || t.length != 3) return null;
      return DateTime(
        2000 + int.parse(d[0]), int.parse(d[1]), int.parse(d[2]),
        int.parse(t[0]), int.parse(t[1]), int.parse(t[2]),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _groups?.fold(0, (s, g) => s + g.photos.length) ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(_groups == null ? 'Galería' : 'Galería ($count fotos)'),
      ),
      body: _groups == null
          ? const Center(child: CircularProgressIndicator())
          : _groups!.isEmpty
              ? const Center(
                  child: Text(
                    'Sin fotos descargadas.\nSincroniza con el ESP32 primero.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _groups!.length,
                  itemBuilder: (_, i) => _GroupCard(group: _groups![i]),
                ),
    );
  }
}

// ─── Card de detección ────────────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final GalleryGroup group;
  const _GroupCard({required this.group});

  String _formatTs(DateTime dt) =>
      '${dt.year}-${_p(dt.month)}-${_p(dt.day)}  ${_p(dt.hour)}:${_p(dt.minute)}:${_p(dt.second)}';

  String _p(int n) => n.toString().padLeft(2, '0');

  Color _eventColor(String? event) => switch (event) {
        'BIRD'     => Colors.green.shade700,
        'PERIODIC' => Colors.blue.shade700,
        'BOOT'     => Colors.orange.shade700,
        _          => Colors.grey.shade600,
      };

  IconData _eventIcon(String? event) => switch (event) {
        'BIRD'     => Icons.flutter_dash,
        'PERIODIC' => Icons.schedule,
        'BOOT'     => Icons.power_settings_new,
        _          => Icons.image_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final ts = group.timestamp;
    final event = group.eventType;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fotos
          SizedBox(
            height: 160,
            child: Row(
              children: group.photos
                  .map((p) => Expanded(child: _PhotoTile(photo: p, allPhotos: group.photos)))
                  .toList(),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Icon(_eventIcon(event), size: 16, color: _eventColor(event)),
                const SizedBox(width: 6),
                Text(
                  event ?? 'Sin evento',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _eventColor(event),
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                Text(
                  ts != null ? _formatTs(ts) : group.timestampRaw,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),

          if (group.hasSensorData) ...[
            const Divider(height: 18, indent: 12, endIndent: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _SensorGrid(sensors: group.sensors),
            ),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ─── Miniatura de foto ────────────────────────────────────────────────────────

class _PhotoTile extends StatelessWidget {
  final StoredPhoto photo;
  final List<StoredPhoto> allPhotos;
  const _PhotoTile({required this.photo, required this.allPhotos});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _PhotoViewer(photo: photo, allPhotos: allPhotos),
        ),
      ),
      child: Image.file(
        File(photo.localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: Colors.grey.shade200,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      ),
    );
  }
}

// ─── Visor de foto a pantalla completa ───────────────────────────────────────

class _PhotoViewer extends StatefulWidget {
  final StoredPhoto photo;
  final List<StoredPhoto> allPhotos;
  const _PhotoViewer({required this.photo, required this.allPhotos});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late int _index;
  late PageController _ctrl;

  @override
  void initState() {
    super.initState();
    _index = widget.allPhotos.indexOf(widget.photo);
    _ctrl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.allPhotos.length}',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: widget.allPhotos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          child: Center(
            child: Image.file(
              File(widget.allPhotos[i].localPath),
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image,
                color: Colors.white54,
                size: 64,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Grid de sensores ─────────────────────────────────────────────────────────

class _SensorGrid extends StatelessWidget {
  final Map<String, double> sensors;
  const _SensorGrid({required this.sensors});

  // Orden canónico de los sensores
  static const _order = [
    'T1_K', 'T2_K', 'T3_K', 'T4_K', 'T5_K', 'T6_K',
    'H1_K', 'H2_K', 'P1_K', 'P2_K',
    'E1_K', 'E2_K',
    'I1_K', 'I2_K', 'I3_K', 'I4_K',
    'W1_K',
  ];

  String _shortKey(String key) => key.replaceAll('_K', '');

  @override
  Widget build(BuildContext context) {
    final ordered = [
      ..._order.where(sensors.containsKey),
      ...sensors.keys.where((k) => !_order.contains(k)),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: ordered.map((key) {
        final val = sensors[key]!;
        return SizedBox(
          width: 80,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _shortKey(key),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  val.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
