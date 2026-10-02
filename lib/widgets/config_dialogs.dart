import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/esp32_service.dart';
import '../services/presigner_config.dart';
import '../services/sync_run_controller.dart';

// Diálogos de configuración compartidos por la pantalla principal y la de
// Configuración (dirección del ESP32, presigner S3 y reinicio del ESP32).

const _keyEsp32Host = 'esp32_host';

/// Host del ESP32 guardado (o el por defecto, esp32cam.local).
Future<String> loadEsp32Host() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyEsp32Host) ?? Esp32Service.defaultStaHost;
}

/// Pide la dirección del ESP32 y la guarda. Devuelve el host nuevo o null si
/// se canceló.
Future<String?> showEsp32HostDialog(BuildContext context) async {
  final ctrl = TextEditingController(text: await loadEsp32Host());
  if (!context.mounted) return null;
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
  if (result == null) return null;
  final host = result.isEmpty ? Esp32Service.defaultStaHost : result;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyEsp32Host, host);
  return host;
}

Future<void> showPresignerDialog(BuildContext context) async {
  final cfg = await PresignerConfig.load();
  // Solo se prellena lo guardado: los valores compilados no se muestran
  // (la URL aparece como pista; el secret nunca).
  final urlCtrl    = TextEditingController(text: cfg.savedUrl);
  final secretCtrl = TextEditingController(text: cfg.savedSecret);
  bool obscure = true;
  if (!context.mounted) return;
  final canReset = cfg.hasBuildDefaults &&
      (cfg.savedUrl.isNotEmpty || cfg.savedSecret.isNotEmpty);
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Configuración S3'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (cfg.hasBuildDefaults)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    cfg.usingBuildDefaults && cfg.savedUrl.isEmpty && cfg.savedSecret.isEmpty
                        ? 'Usando la configuración incluida en la app. Escribe valores '
                            'solo si quieres reemplazarla.'
                        : cfg.usingBuildDefaults
                            ? 'Usando en parte la configuración incluida en la app '
                                '(los campos vacíos).'
                            : 'Usando la configuración guardada en este teléfono. '
                                '«Restablecer» vuelve a la incluida en la app.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: 'URL del presigner',
                  hintText: cfg.urlFromBuild
                      ? PresignerConfig.buildUrl
                      : 'https://xxxx.lambda-url.us-east-1.on.aws/',
                  helperText: cfg.urlFromBuild ? 'Vacío = incluida en la app' : null,
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: secretCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'Secret',
                  hintText: cfg.secretFromBuild ? '•••••••• (incluido en la app)' : null,
                  helperText: cfg.secretFromBuild ? 'Vacío = incluido en la app' : null,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (canReset)
            TextButton(
              onPressed: () async {
                await PresignerConfig.reset();
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Se restableció la configuración incluida en la app.'),
                  ));
                }
              },
              child: const Text('Restablecer'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              await PresignerConfig.save(url: urlCtrl.text, secret: secretCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
}

/// Confirma y reinicia el ESP32 (POST /reboot + espera). No permite hacerlo
/// durante una sincronización. Devuelve el resultado, o null si no se reinició.
Future<RebootResult?> confirmAndRebootEsp32(BuildContext context) async {
  if (SyncRunController.instance.running) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Espera a que termine la sincronización en curso para reiniciar el ESP32.'),
    ));
    return null;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.restart_alt),
      title: const Text('¿Reiniciar el ESP32?'),
      content: const Text(
        'La placa se reinicia y vuelve en unos segundos. Sirve, por ejemplo, '
        'cuando la tarjeta SD deja de responder. Mientras reinicia no se '
        'guardan fotos ni eventos.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reiniciar')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final esp32 = Esp32Service(staHost: await loadEsp32Host());
  if (!context.mounted) return null;
  return showDialog<RebootResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RebootDialog(esp32: esp32),
  );
}

/// Diálogo que reinicia el ESP32 y espera a que vuelva.
class RebootDialog extends StatefulWidget {
  final Esp32Service esp32;
  const RebootDialog({super.key, required this.esp32});

  @override
  State<RebootDialog> createState() => _RebootDialogState();
}

class _RebootDialogState extends State<RebootDialog> {
  String _message = 'Enviando la orden de reinicio…';
  RebootResult? _result;
  bool _showDetail = false;

  @override
  void initState() {
    super.initState();
    widget.esp32
        .rebootAndWait(onProgress: (m) {
          if (mounted) setState(() => _message = m);
        })
        .then((r) {
          if (mounted) setState(() => _result = r);
        });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final (Color color, IconData icon) = switch (r?.outcome) {
      RebootOutcome.ok => (Colors.green.shade600, Icons.check_circle),
      RebootOutcome.sdNoResponde => (Colors.red.shade600, Icons.sd_card_alert),
      RebootOutcome.noVolvio || RebootOutcome.fallo => (Colors.orange.shade700, Icons.warning_amber),
      null => (Colors.grey, Icons.restart_alt),
    };
    return PopScope(
      canPop: r != null,
      child: AlertDialog(
        icon: r == null
            ? const SizedBox(width: 32, height: 32, child: CircularProgressIndicator())
            : Icon(icon, color: color, size: 32),
        title: Text(r == null ? 'Reiniciando ESP32' : 'Reinicio del ESP32'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r?.message ?? _message),
            if (r?.technical != null) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _showDetail = !_showDetail),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Detalle técnico',
                        style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)),
                    Icon(_showDetail ? Icons.expand_less : Icons.expand_more, size: 18),
                  ],
                ),
              ),
              if (_showDetail)
                SelectableText(r!.technical!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ],
          ],
        ),
        actions: [
          if (r != null)
            FilledButton(onPressed: () => Navigator.pop(context, r), child: const Text('Cerrar')),
        ],
      ),
    );
  }
}
