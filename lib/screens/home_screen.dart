import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/esp32_service.dart';
import '../services/backend_service.dart';
import '../services/esp32_sync_service.dart';
import '../services/backend_sync_service.dart';
import '../services/local_storage_service.dart';
import '../models/sync_progress.dart';
import 'setup_screen.dart';
import 'gallery_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = LocalStorageService();
  final _log = <SyncProgress>[];
  final _scrollCtrl = ScrollController();

  bool _syncing = false;
  bool _esp32Reachable = false;
  bool _checking = false;
  String _esp32Host = Esp32Service.defaultStaHost;

  ({DateTime? at, int photos, int lines})? _lastSync;
  PendingCounts? _pending;

  @override
  void initState() {
    super.initState();
    _loadEsp32Host().then((_) => _checkConnection());
    _loadStats();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final last = await Esp32SyncService.lastSyncInfo();
    final pending = await _storage.pendingCounts();
    if (mounted) setState(() { _lastSync = last; _pending = pending; });
  }

  Future<void> _loadEsp32Host() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('esp32_host');
    if (mounted && saved != null) setState(() => _esp32Host = saved);
  }

  Esp32Service _makeEsp32Service() => Esp32Service(staHost: _esp32Host);

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    final ok = await _makeEsp32Service().isReachable();
    if (mounted) setState(() { _esp32Reachable = ok; _checking = false; });
  }

  Future<String> _getBackendUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('backend_url') ?? '';
  }

  void _runStream(Stream<SyncProgress> stream) {
    setState(() { _syncing = true; _log.clear(); });
    stream.listen(
      (p) {
        setState(() => _log.add(p));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.animateTo(
              _scrollCtrl.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
            );
          }
        });
      },
      onDone: () async {
        await _loadStats();
        if (mounted) setState(() => _syncing = false);
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _log.add(SyncProgress('Error inesperado: $e', isError: true));
            _syncing = false;
          });
        }
      },
    );
  }

  void _startEsp32Sync() {
    _runStream(
      Esp32SyncService(_makeEsp32Service(), _storage).sync(),
    );
  }

  Future<void> _startBackendSync() async {
    final url = await _getBackendUrl();
    if (url.isEmpty) {
      await _showBackendDialog();
      return;
    }
    _runStream(
      BackendSyncService(BackendService(url), _storage).sync(),
    );
  }

  Future<void> _showEsp32HostDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final ctrl = TextEditingController(text: _esp32Host);
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dirección del ESP32'),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            hintText: Esp32Service.defaultStaHost,
            helperText: 'Deja vacío para usar esp32cam.local',
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final host = result.isEmpty ? Esp32Service.defaultStaHost : result;
    await prefs.setString('esp32_host', host);
    if (mounted) setState(() => _esp32Host = host);
    _checkConnection();
  }

  Future<void> _showBackendDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final ctrl = TextEditingController(text: prefs.getString('backend_url') ?? '');
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('URL del servidor'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'http://192.168.x.x:8000',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await prefs.setString('backend_url', result);
    }
  }

  Future<void> _openSetup() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const SetupScreen()),
    );
    if (ok == true) _checkConnection();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Brumaire'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Galería',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GalleryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.router_outlined),
            tooltip: 'IP del ESP32',
            onPressed: _showEsp32HostDialog,
          ),
          IconButton(
            icon: const Icon(Icons.dns_outlined),
            tooltip: 'Servidor backend',
            onPressed: _showBackendDialog,
          ),
          IconButton(
            icon: const Icon(Icons.wifi_tethering),
            tooltip: 'Configurar ESP32',
            onPressed: _openSetup,
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            reachable: _esp32Reachable,
            checking: _checking,
            host: _esp32Host,
            onCheck: _checkConnection,
          ),
          _StatsCard(lastSync: _lastSync, pending: _pending),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _syncing ? null : _startEsp32Sync,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Descargar SD'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _syncing ? null : _startBackendSync,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Subir al servidor'),
                  ),
                ),
              ],
            ),
          ),
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: LinearProgressIndicator(),
            ),
          const Divider(height: 1),
          Expanded(
            child: _log.isEmpty
                ? const Center(
                    child: Text(
                      'Descarga datos del ESP32 o sube\nlos pendientes al servidor.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => _LogLine(entry: _log[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets ──────────────────────────────────────────────────────────────────

class _StatsCard extends StatelessWidget {
  final ({DateTime? at, int photos, int lines})? lastSync;
  final PendingCounts? pending;

  const _StatsCard({this.lastSync, this.pending});

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'ahora mismo';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes}m';
    if (d.inHours < 24) return 'hace ${d.inHours}h';
    return 'hace ${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _StatBox(
              label: lastSync?.at != null
                  ? 'Último sync SD · ${_timeAgo(lastSync!.at!)}'
                  : 'Sin sync con SD',
              lines: [
                if (lastSync != null && lastSync!.at != null) ...[
                  '↓ ${lastSync!.photos} fotos nuevas',
                  '↓ ${lastSync!.lines} líneas nuevas',
                ] else
                  'Nunca sincronizado',
              ],
              color: colorScheme.surfaceContainerLow,
              textTheme: textTheme,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatBox(
              label: 'Pendiente de subir',
              lines: [
                '${pending?.photos ?? 0} fotos · ${pending?.logLines ?? 0} líneas',
                if ((pending?.invalidTimestamps ?? 0) > 0)
                  '⚠ ${pending!.invalidTimestamps} con TS inválido',
              ],
              color: colorScheme.surfaceContainerLow,
              textTheme: textTheme,
              warning: (pending?.invalidTimestamps ?? 0) > 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final List<String> lines;
  final Color color;
  final TextTheme textTheme;
  final bool warning;

  const _StatBox({
    required this.label,
    required this.lines,
    required this.color,
    required this.textTheme,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelSmall?.copyWith(color: Colors.grey[600])),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: textTheme.bodySmall?.copyWith(
                color: warning && line.startsWith('⚠') ? Colors.orange[800] : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final bool reachable;
  final bool checking;
  final String host;
  final VoidCallback onCheck;

  const _ConnectionBanner({
    required this.reachable,
    required this.checking,
    required this.host,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final color = reachable ? Colors.green : Colors.orange;
    final bg = reachable ? Colors.green.shade50 : Colors.orange.shade50;
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          if (checking)
            SizedBox(
              height: 16, width: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(
              reachable ? Icons.check_circle : Icons.warning_amber,
              size: 16,
              color: color,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reachable
                  ? 'ESP32 conectado ($host)'
                  : 'ESP32 no encontrado ($host)',
              style: TextStyle(color: color.shade800, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: checking ? null : onCheck,
            child: const Text('Verificar'),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final SyncProgress entry;
  const _LogLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    Color? color;
    if (entry.isError) color = Colors.red.shade700;
    if (entry.isWarning) color = Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        entry.message,
        style: TextStyle(fontSize: 13, fontFamily: 'monospace', color: color),
      ),
    );
  }
}
