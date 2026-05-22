import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/esp32_service.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String _status = '';
  bool _loading = false;
  bool _obscure = true;

  Future<void> _configure() async {
    final ssid = _ssidCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    if (ssid.isEmpty || pass.isEmpty) {
      setState(() => _status = 'Completa SSID y contraseña.');
      return;
    }
    setState(() {
      _loading = true;
      _status = 'Enviando configuración al ESP32...';
    });
    try {
      await Esp32Service().configureWifi(ssid, pass);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('esp32_configured', true);
      await prefs.setString('hotspot_ssid', ssid);
      if (!mounted) return;
      setState(() => _status = '✓ Configuración enviada. El ESP32 está reiniciando...');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _status = 'Error: $e\n¿Estás conectado a ESP32_CONFIG_CAM?');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isError = _status.startsWith('Error');
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar ESP32')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Step(
              number: '1',
              text: 'Activa el hotspot de tu teléfono y anota su SSID y contraseña.',
            ),
            _Step(
              number: '2',
              text:
                  'Conecta este teléfono a la red "ESP32_CONFIG_CAM" (contraseña: 12345678). Esto lo hace el ESP32 la primera vez.',
            ),
            _Step(
              number: '3',
              text:
                  'Ingresa abajo las credenciales del hotspot de tu teléfono. El ESP32 las guardará y se conectará automáticamente a partir de ahora.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _ssidCtrl,
              decoration: const InputDecoration(
                labelText: 'SSID del hotspot',
                hintText: 'Nombre de tu punto de acceso',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.wifi_tethering),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Contraseña del hotspot',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: _loading ? null : _configure,
                icon: _loading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send),
                label: const Text('Enviar configuración'),
              ),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                _status,
                style: TextStyle(
                  color: isError
                      ? Colors.red.shade700
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final String number;
  final String text;
  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              number,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
        ],
      ),
    );
  }
}
