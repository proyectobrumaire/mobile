import 'package:flutter/material.dart';
import '../services/esp32_service.dart';
import '../services/esp32_sync_service.dart';
import '../services/local_storage_service.dart';
import '../services/sync_run_controller.dart';
import '../models/sync_progress.dart';
import '../widgets/sync_progress_view.dart';
import '../widgets/config_dialogs.dart';
import 'settings_screen.dart';
import 'gallery_screen.dart';
import 'events_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = LocalStorageService();
  final _sync = SyncRunController.instance;
  int _seenRuns = 0;

  Esp32Status _esp32Status = Esp32Status.noEncontrado;
  String? _statusDetail;
  bool _checking = false;
  String _esp32Host = Esp32Service.defaultStaHost;

  ({DateTime? at, int photos, int lines})? _lastSync;
  PendingCounts? _pending;

  @override
  void initState() {
    super.initState();
    _seenRuns = _sync.finishedRuns;
    _sync.addListener(_onSyncChanged);
    _loadEsp32Host().then((_) => _checkConnection());
    _loadStats();
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
      _loadStats();
    }
    setState(() {});
  }

  Future<void> _loadStats() async {
    final last = await Esp32SyncService.lastSyncInfo();
    final pending = await _storage.pendingCounts();
    if (mounted) setState(() { _lastSync = last; _pending = pending; });
  }

  Future<void> _loadEsp32Host() async {
    final host = await loadEsp32Host();
    if (mounted) setState(() => _esp32Host = host);
  }

  Esp32Service _makeEsp32Service() => Esp32Service(staHost: _esp32Host);

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    final esp = _makeEsp32Service();
    var health = await esp.checkStatus();
    // "SD Busy" es transitorio: reintentar un par de veces antes de mostrarlo.
    for (var i = 0; i < 2 && health.status == Esp32Status.sdOcupada; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      health = await esp.checkStatus();
    }
    if (mounted) {
      setState(() {
        _esp32Status = health.status;
        _statusDetail = health.technical;
        _checking = false;
      });
    }
  }

  Future<void> _reboot() async {
    final result = await confirmAndRebootEsp32(context);
    if (!mounted || result == null) return;
    setState(() {
      _esp32Status = result.status;
      _statusDetail = result.technical;
    });
    _checkConnection();
  }

  /// Abre Configuración y, al volver, recarga el host y el estado del ESP32
  /// (pudo cambiar la dirección o reiniciarse la placa).
  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (!mounted) return;
    await _loadEsp32Host();
    _checkConnection();
  }

  /// "Descargar log": hora + log.txt + /reset_log (sin fotos).
  void _startLogSync() {
    final esp32 = _makeEsp32Service();
    _sync.start(
      SyncKind.descargaLog,
      (isCancelled) => Esp32SyncService(esp32, _storage).syncLog(isCancelled: isCancelled),
    );
  }

  /// "Descargar fotos": pregunta el modo (un lote o continua) y arranca.
  Future<void> _startPhotoSync() async {
    var continuous = await Esp32SyncService.loadContinuousPref();
    if (!mounted) return;
    final start = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          icon: const Icon(Icons.sd_card_outlined),
          title: const Text('Descargar fotos'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Se descargan las fotos de la SD. Cada foto se borra de la SD '
                'cuando ya quedó guardada en el teléfono. (El registro de sensores '
                'se descarga con «Descargar log».)',
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Descarga continua'),
                subtitle: Text(continuous
                    ? 'Repite lote tras lote hasta vaciar la SD. Puede tardar; '
                        'puedes cancelar en cualquier momento.'
                    : 'Solo un lote (hasta 20 archivos).'),
                value: continuous,
                onChanged: (v) => setDialog(() => continuous = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Iniciar'),
            ),
          ],
        ),
      ),
    );
    if (start != true) return;
    await Esp32SyncService.saveContinuousPref(continuous);
    final esp32 = _makeEsp32Service();
    _sync.start(
      SyncKind.descargaFotos,
      (isCancelled) => Esp32SyncService(esp32, _storage)
          .syncPhotos(continuous: continuous, isCancelled: isCancelled),
    );
  }

  Future<void> _openGallery() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    final state = _sync.state;
    final downloading = _sync.running && (state?.kind.isDescarga ?? false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Brumaire'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Galería',
            onPressed: _openGallery,
          ),
          IconButton(
            icon: const Icon(Icons.timeline),
            tooltip: 'Eventos',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EventsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Configuración',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            status: _esp32Status,
            detail: _statusDetail,
            onReboot: _reboot,
            checking: _checking,
            host: _esp32Host,
            onCheck: _checkConnection,
          ),
          // Acciones con el ESP32 (sección de conexión): dos descargas separadas.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: downloading
                ? SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _sync.cancelRequested ? null : _sync.cancel,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(_sync.cancelRequested
                          ? 'Cancelando…'
                          : 'Cancelar descarga'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _sync.running ? null : _startLogSync,
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('Descargar log', textAlign: TextAlign.center),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _sync.running ? null : _startPhotoSync,
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: const Text('Descargar fotos', textAlign: TextAlign.center),
                        ),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _StatsCard(lastSync: _lastSync, pending: _pending, onTapPending: _openGallery),
          ),
          const Divider(height: 1),
          Expanded(
            child: state == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Descarga las fotos y lecturas de la estación.\n'
                                'Para subirlas al servidor, abre la Galería.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SyncProgressView(
                      state: state,
                      cancelRequested: _sync.cancelRequested,
                      onCancel: _sync.cancel,
                      onClose: _sync.clear,
                    ),
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
  final VoidCallback onTapPending;

  const _StatsCard({this.lastSync, this.pending, required this.onTapPending});

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
                  '↓ ${lastSync!.lines} lecturas nuevas',
                ] else
                  'Nunca sincronizado',
              ],
              color: colorScheme.surfaceContainerLow,
              textTheme: textTheme,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTapPending,
              child: _StatBox(
                label: 'Pendiente de subir ›',
                lines: [
                  '${pending?.photos ?? 0} fotos · ${pending?.logLines ?? 0} lecturas',
                  if ((pending?.invalidTimestamps ?? 0) > 0)
                    '⚠ ${pending!.invalidTimestamps} con fecha inválida',
                  'Súbelas desde la Galería',
                ],
                color: colorScheme.surfaceContainerLow,
                textTheme: textTheme,
                warning: (pending?.invalidTimestamps ?? 0) > 0,
              ),
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
  final Esp32Status status;
  final String? detail;
  final bool checking;
  final String host;
  final VoidCallback onCheck;
  final VoidCallback onReboot;

  const _ConnectionBanner({
    required this.status,
    required this.checking,
    required this.host,
    required this.onCheck,
    required this.onReboot,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final (MaterialColor color, IconData icon, String text) = switch (status) {
      Esp32Status.conectado => (Colors.green, Icons.check_circle, 'ESP32 conectado ($host)'),
      // Transitorio: no alarmar.
      Esp32Status.sdOcupada =>
        (Colors.green, Icons.check_circle, 'ESP32 conectado ($host) · SD ocupada, reintenta en un momento'),
      Esp32Status.sdNoResponde =>
        (Colors.red, Icons.sd_card_alert, 'ESP32 conectado, pero la tarjeta SD no responde'),
      Esp32Status.modoAp =>
        (Colors.orange, Icons.wifi_tethering, 'ESP32 en modo configuración (sin WiFi)'),
      Esp32Status.noEncontrado =>
        (Colors.orange, Icons.warning_amber, 'ESP32 no encontrado ($host)'),
    };
    final sdDown = status == Esp32Status.sdNoResponde;
    return Container(
      width: double.infinity,
      color: color.shade50,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          if (checking)
            SizedBox(
              height: 16, width: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 18, color: color.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: color.shade800,
                    fontSize: 13,
                    fontWeight: sdDown ? FontWeight.w600 : null,
                  ),
                ),
                if (sdDown)
                  Text(
                    'Las fotos y eventos no se están guardando. Reinicia la placa.',
                    style: TextStyle(color: color.shade800, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (sdDown)
            TextButton(onPressed: checking ? null : onReboot, child: const Text('Reiniciar'))
          else
            TextButton(
              onPressed: checking ? null : onCheck,
              child: const Text('Verificar'),
            ),
        ],
      ),
    );
  }
}
