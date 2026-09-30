// Eventos estructurados que emiten los servicios de sincronización
// (Esp32SyncService y BackendSyncService) y el estado que arma la UI con ellos.

/// Qué sincronización se está ejecutando.
enum SyncKind { descarga, subida }

/// Pasos posibles de una sincronización, en el orden en que se muestran.
enum SyncStep {
  conectar('Conectar con el ESP32'),
  hora('Sincronizar la hora'),
  log('Procesar el log de sensores'),
  listar('Revisar la SD'),
  fotos('Descargar fotos'),
  subirFotos('Subir fotos'),
  subirLog('Subir lecturas de sensores'),
  resumen('Resumen');

  final String titulo;
  const SyncStep(this.titulo);
}

enum StepStatus { enCurso, ok, advertencia, error, omitido }

/// Incidencia puntual dentro de un paso (p. ej. una foto que no se pudo
/// descargar). Se acumulan en el paso y se muestran como lista expandible.
class SyncIssue {
  final String message;
  final String? technical;
  final bool isError;
  const SyncIssue(this.message, {this.technical, this.isError = true});
}

/// Resumen final de una sincronización.
class SyncSummary {
  final SyncKind kind;
  final int newPhotos;
  final int repeatedPhotos;
  final int newLines;
  final int uploadedPhotos;
  final int uploadedLines;

  /// Fotos que ya estaban subidas (de versiones anteriores) y se borraron del teléfono.
  final int purgedPhotos;
  final int errors;
  final int warnings;
  final bool cancelled;

  /// log.txt no se procesó (cancelación o error antes de llegar a él).
  final bool logSkipped;

  /// Error que impidió empezar (p. ej. ESP32 no encontrado).
  final bool fatal;

  const SyncSummary({
    required this.kind,
    this.newPhotos = 0,
    this.repeatedPhotos = 0,
    this.newLines = 0,
    this.uploadedPhotos = 0,
    this.uploadedLines = 0,
    this.purgedPhotos = 0,
    this.errors = 0,
    this.warnings = 0,
    this.cancelled = false,
    this.logSkipped = false,
    this.fatal = false,
  });

  bool get hasErrors => errors > 0;

  /// Título corto del resultado.
  String get title {
    final what = kind == SyncKind.descarga ? 'Descarga' : 'Subida';
    if (fatal) return '$what fallida';
    if (cancelled) return '$what cancelada';
    if (errors > 0) return '$what terminada con errores';
    return '$what completada';
  }

  /// Texto corto, p. ej. "12 fotos nuevas, 240 lecturas, 1 error".
  String get text {
    final parts = <String>[];
    if (kind == SyncKind.descarga) {
      parts.add(plural(newPhotos, 'foto nueva', 'fotos nuevas'));
      if (repeatedPhotos > 0) {
        parts.add(plural(repeatedPhotos, 'repetida', 'repetidas'));
      }
      parts.add(logSkipped ? 'log no procesado' : plural(newLines, 'lectura', 'lecturas'));
    } else {
      parts.add(plural(uploadedPhotos, 'foto subida', 'fotos subidas'));
      parts.add(plural(uploadedLines, 'lectura subida', 'lecturas subidas'));
      if (purgedPhotos > 0) {
        parts.add('${plural(purgedPhotos, 'foto ya subida borrada', 'fotos ya subidas borradas')} del teléfono');
      }
    }
    parts.add(errors == 0 ? 'sin errores' : plural(errors, 'error', 'errores'));
    if (warnings > 0) parts.add(plural(warnings, 'advertencia', 'advertencias'));
    final base = parts.join(', ');
    return cancelled ? 'Alcanzó a hacer: $base' : base;
  }
}

String plural(int n, String singular, String pluralForm) =>
    '$n ${n == 1 ? singular : pluralForm}';

/// Un evento de progreso: el nuevo estado de un paso. Opcionalmente trae una
/// incidencia para acumular en ese paso, o el resumen final.
class SyncProgress {
  final SyncStep step;
  final StepStatus status;
  final String message;
  /// Progreso determinado del tramo actual (p. ej. el lote: 7 de 20).
  final int? current;
  final int? total;

  /// Texto del avance acumulado cuando no se conoce el total
  /// (p. ej. "34 fotos descargadas, quedan más en la SD").
  final String? overall;

  /// Si es true, bajo `overall` se muestra una barra indeterminada.
  final bool overallOngoing;
  final String? technical;
  final SyncIssue? issue;
  final SyncSummary? summary;

  const SyncProgress(
    this.step,
    this.status,
    this.message, {
    this.current,
    this.total,
    this.overall,
    this.overallOngoing = false,
    this.technical,
    this.issue,
    this.summary,
  });

  factory SyncProgress.done(SyncSummary summary) =>
      SyncProgress(SyncStep.resumen, StepStatus.ok, summary.text, summary: summary);
}

/// Estado de un paso tal como lo muestra la UI.
class SyncStepState {
  final SyncStep step;
  StepStatus status;
  String message;
  int? current;
  int? total;
  String? overall;
  bool overallOngoing = false;
  String? technical;
  final List<SyncIssue> issues = [];

  SyncStepState(this.step, this.status, this.message);

  double? get fraction =>
      (current != null && total != null && total! > 0) ? current! / total! : null;
}

/// Acumula los eventos de una sincronización. Lógica pura, sin Flutter.
class SyncRunState {
  final SyncKind kind;
  final _steps = <SyncStep, SyncStepState>{};
  SyncSummary? summary;
  bool running = true;

  SyncRunState(this.kind);

  List<SyncStepState> get steps => _steps.values.toList();

  void apply(SyncProgress p) {
    if (p.summary != null) {
      summary = p.summary;
      return;
    }
    final s = _steps.putIfAbsent(p.step, () => SyncStepState(p.step, p.status, p.message));
    s
      ..status = p.status
      ..message = p.message
      ..current = p.current
      ..total = p.total
      ..overall = p.overall
      ..overallOngoing = p.overallOngoing;
    if (p.technical != null) s.technical = p.technical;
    if (p.issue != null) s.issues.add(p.issue!);
  }

  /// Marca como error el paso en curso cuando el stream falla de forma inesperada.
  void failUnexpected(Object e) {
    final current = _steps.values.where((s) => s.status == StepStatus.enCurso).lastOrNull;
    if (current != null) {
      current
        ..status = StepStatus.error
        ..message = 'Se interrumpió por un error inesperado.'
        ..technical = '$e';
    }
    summary ??= SyncSummary(kind: kind, errors: 1);
    running = false;
  }
}
