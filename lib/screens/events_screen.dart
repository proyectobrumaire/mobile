import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/event_record.dart';
import '../services/cloud_gallery_service.dart';
import '../services/error_messages.dart';
import '../services/local_storage_service.dart';
import '../services/sync_run_controller.dart';
import '../widgets/event_timeline.dart';
import '../widgets/truncated_notice.dart';

/// Visor de eventos del log (excepto BIRD, que está en la galería):
/// pestaña Local (pendientes de subir) y Cloud (POST /events).
class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Eventos'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.phone_android), text: 'Local'),
              Tab(icon: Icon(Icons.cloud_outlined), text: 'Cloud'),
            ],
          ),
        ),
        body: const TabBarView(children: [_LocalEventsTab(), _CloudEventsTab()]),
      ),
    );
  }
}

// ─── Local ────────────────────────────────────────────────────────────────────

class _LocalEventsTab extends StatefulWidget {
  const _LocalEventsTab();

  @override
  State<_LocalEventsTab> createState() => _LocalEventsTabState();
}

class _LocalEventsTabState extends State<_LocalEventsTab>
    with AutomaticKeepAliveClientMixin {
  final _storage = LocalStorageService();
  final _sync = SyncRunController.instance;
  int _seenRuns = 0;

  List<EventRecord>? _events;
  String? _error;
  Set<String> _selected = eventCategories.toSet();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _seenRuns = _sync.finishedRuns;
    _sync.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    _sync.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (_sync.finishedRuns != _seenRuns) {
      _seenRuns = _sync.finishedRuns;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final entries = await _storage.pendingEventEntries();
      if (mounted) setState(() { _events = eventsFromLogEntries(entries); _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null) {
      return Center(child: Text('No se pudo leer el log local:\n$_error', textAlign: TextAlign.center));
    }
    final events = _events;
    if (events == null) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        const SizedBox(height: 10),
        EventFilterChips(
          selected: _selected,
          counts: countByCategory(events),
          onChanged: (s) => setState(() => _selected = s),
        ),
        const Divider(height: 16),
        Expanded(
          child: EventTimeline(
            days: groupEventsByDay(events, _selected),
            onRefresh: _load,
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Eventos descargados que aún no se suben. Al subirlos pasan a la pestaña Cloud.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ),
            emptyMessage: events.isEmpty
                ? 'No hay eventos pendientes en el teléfono.\nLos ya subidos están en la pestaña Cloud.'
                : 'Ningún evento coincide con el filtro.',
          ),
        ),
      ],
    );
  }
}

// ─── Cloud ────────────────────────────────────────────────────────────────────

class _CloudEventsTab extends StatefulWidget {
  const _CloudEventsTab();

  @override
  State<_CloudEventsTab> createState() => _CloudEventsTabState();
}

class _CloudEventsTabState extends State<_CloudEventsTab>
    with AutomaticKeepAliveClientMixin {
  static const _ranges = ['Hoy', '7 días', '30 días'];

  int _rangeIdx = 0;
  Set<String> _selected = eventCategories.toSet();
  bool _loading = false;
  String? _error;
  String? _errorDetail;
  CloudPage<CloudEvent>? _page;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  ({DateTime from, DateTime to}) _range() {
    final now = DateTime.now();
    return switch (_rangeIdx) {
      0 => (from: DateTime(now.year, now.month, now.day), to: now),
      2 => (from: now.subtract(const Duration(days: 30)), to: now),
      _ => (from: now.subtract(const Duration(days: 7)), to: now),
    };
  }

  Future<void> _fetch() async {
    if (_selected.isEmpty) {
      setState(() { _page = const CloudPage([]); _error = null; });
      return;
    }
    setState(() { _loading = true; _error = null; _errorDetail = null; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString('presigner_url') ?? '';
      final secret = prefs.getString('presigner_secret') ?? '';
      if (url.isEmpty || secret.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'Configura el servidor (ícono «Presigner S3» en la pantalla principal).';
          _loading = false;
        });
        return;
      }
      final r = _range();
      final page = await CloudGalleryService(url, secret).fetchEvents(
        from: r.from,
        to: r.to,
        types: cloudTypesFor(_selected),
      );
      if (!mounted) return;
      setState(() { _page = page; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorMessages.cloud(e);
        _errorDetail = '$e';
        _loading = false;
      });
    }
  }

  List<EventRecord> get _records => [
        for (final e in _page?.items ?? const <CloudEvent>[])
          EventRecord(timestamp: e.timestamp.toLocal(), event: e.event, sensors: e.env),
      ];

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 0),
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
        const SizedBox(height: 6),
        EventFilterChips(
          selected: _selected,
          enabled: !_loading,
          onChanged: (s) {
            setState(() => _selected = s);
            _fetch();
          },
        ),
        const Divider(height: 16),
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
    final records = _records;
    return EventTimeline(
      days: groupEventsByDay(records, _selected),
      onRefresh: _fetch,
      header: _page?.truncated == true
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: TruncatedNotice(what: 'eventos', femenino: false),
            )
          : null,
      emptyMessage: _selected.isEmpty
          ? 'Elige al menos un tipo de evento.'
          : 'Sin eventos en este período.',
    );
  }
}
