import 'package:flutter/material.dart';
import '../models/sync_progress.dart';

/// Muestra una sincronización como pasos con estado, barra de progreso,
/// resumen final y detalle técnico expandible.
class SyncProgressView extends StatelessWidget {
  final SyncRunState state;
  final bool cancelRequested;
  final VoidCallback? onCancel;
  final VoidCallback? onClose;

  const SyncProgressView({
    super.key,
    required this.state,
    this.cancelRequested = false,
    this.onCancel,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final summary = state.summary;
    final running = state.running;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final what = switch (state.kind) {
      SyncKind.descargaLog => 'Descargando el log',
      SyncKind.descargaFotos => 'Descargando fotos',
      SyncKind.subida => 'Subiendo al servidor',
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (running)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  _statusIcon(_overallStatus(summary), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    running
                        ? (cancelRequested ? 'Cancelando… (termina la operación en curso)' : '$what…')
                        : summary?.title ?? 'Sincronización terminada',
                    style: text.titleMedium,
                  ),
                ),
                if (running && onCancel != null)
                  TextButton.icon(
                    onPressed: cancelRequested ? null : onCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Cancelar'),
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                  )
                else if (!running && onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Ocultar',
                    onPressed: onClose,
                  ),
              ],
            ),
            if (!running && summary != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(
                  summary.text,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 8),
            for (final s in state.steps) _StepTile(step: s, running: running),
          ],
        ),
      ),
    );
  }

  static StepStatus _overallStatus(SyncSummary? s) {
    if (s == null) return StepStatus.ok;
    if (s.fatal || s.errors > 0) return StepStatus.error;
    if (s.cancelled || s.warnings > 0) return StepStatus.advertencia;
    return StepStatus.ok;
  }
}

Widget _statusIcon(StepStatus status, {double size = 20}) => switch (status) {
      StepStatus.enCurso => SizedBox(
          width: size,
          height: size,
          child: const Padding(
            padding: EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      StepStatus.ok => Icon(Icons.check_circle, color: Colors.green.shade600, size: size),
      StepStatus.advertencia =>
        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: size),
      StepStatus.error => Icon(Icons.error, color: Colors.red.shade600, size: size),
      StepStatus.omitido =>
        Icon(Icons.remove_circle_outline, color: Colors.grey.shade500, size: size),
    };

class _StepTile extends StatelessWidget {
  final SyncStepState step;
  final bool running;
  const _StepTile({required this.step, required this.running});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fraction = step.fraction;
    final active = step.status == StepStatus.enCurso;
    final msgColor = switch (step.status) {
      StepStatus.error => Colors.red.shade700,
      StepStatus.advertencia => Colors.orange.shade900,
      _ => Colors.grey.shade700,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _statusIcon(step.status),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.step.titulo,
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (step.message.isNotEmpty)
                  Text(step.message, style: text.bodySmall?.copyWith(color: msgColor)),
                if (active && fraction != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${step.current}/${step.total}', style: text.labelSmall),
                    ],
                  ),
                ],
                if (step.overall != null) ...[
                  const SizedBox(height: 4),
                  Text(step.overall!,
                      style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  if (running && active && step.overallOngoing)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: LinearProgressIndicator(minHeight: 3),
                    ),
                ],
                if (step.issues.isNotEmpty)
                  _Expandable(
                    label: step.issues.length == 1
                        ? 'Ver 1 problema'
                        : 'Ver ${step.issues.length} problemas',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final i in step.issues) _IssueTile(issue: i),
                      ],
                    ),
                  ),
                if (step.technical != null)
                  _Expandable(
                    label: 'Detalle técnico',
                    child: _TechText(step.technical!),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  final SyncIssue issue;
  const _IssueTile({required this.issue});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ${issue.message}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: issue.isError ? Colors.red.shade700 : Colors.orange.shade900,
                ),
          ),
          if (issue.technical != null) _TechText(issue.technical!),
        ],
      ),
    );
  }
}

class _TechText extends StatelessWidget {
  final String text;
  const _TechText(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }
}

/// Bloque plegable simple (cerrado por defecto).
class _Expandable extends StatefulWidget {
  final String label;
  final Widget child;
  const _Expandable({required this.label, required this.child});

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
              ],
            ),
          ),
        ),
        if (_open) widget.child,
      ],
    );
  }
}
