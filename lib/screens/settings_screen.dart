import 'package:flutter/material.dart';
import '../services/presigner_config.dart';
import '../services/sync_run_controller.dart';
import '../widgets/config_dialogs.dart';
import 'setup_screen.dart';

/// Configuración: ESP32 (dirección, WiFi, reinicio) y servidor (presigner).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _sync = SyncRunController.instance;
  String? _host;
  PresignerConfig? _presigner;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    _sync.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final host = await loadEsp32Host();
    final cfg = await PresignerConfig.load();
    if (mounted) setState(() { _host = host; _presigner = cfg; });
  }

  String _presignerSubtitle() {
    final c = _presigner;
    if (c == null) return '';
    if (!c.isComplete) return 'Sin configurar';
    if (c.usingBuildDefaults && c.savedUrl.isEmpty && c.savedSecret.isEmpty) {
      return 'Configuración incluida en la app';
    }
    return 'Personalizada';
  }

  Future<void> _editHost() async {
    await showEsp32HostDialog(context);
    _load();
  }

  Future<void> _openWifiSetup() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const SetupScreen()),
    );
  }

  Future<void> _editPresigner() async {
    await showPresignerDialog(context);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _sync.running;
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: ListView(
        children: [
          const _SectionHeader('ESP32'),
          ListTile(
            leading: const Icon(Icons.router_outlined),
            title: const Text('Dirección del ESP32'),
            subtitle: Text(_host ?? ''),
            onTap: _editHost,
          ),
          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('Configurar WiFi del ESP32'),
            subtitle: const Text('Conecta la placa a tu red (modo configuración)'),
            onTap: _openWifiSetup,
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reiniciar ESP32'),
            subtitle: Text(busy
                ? 'No disponible durante una sincronización'
                : 'Útil si la tarjeta SD deja de responder'),
            enabled: !busy,
            onTap: busy ? null : () => confirmAndRebootEsp32(context),
          ),
          const Divider(),
          const _SectionHeader('Servidor'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Presigner S3'),
            subtitle: Text(_presignerSubtitle()),
            onTap: _editPresigner,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
