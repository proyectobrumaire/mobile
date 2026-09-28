import 'package:flutter/foundation.dart';
import '../models/sync_progress.dart';

/// Ejecuta una sincronización a la vez para toda la app (pantalla principal y
/// galería comparten la misma instancia) y expone su estado a la UI.
class SyncRunController extends ChangeNotifier {
  SyncRunController._();
  static final instance = SyncRunController._();

  SyncRunState? _state;
  bool _cancelRequested = false;

  /// Se incrementa cada vez que termina una corrida (para recargar datos).
  int finishedRuns = 0;

  SyncRunState? get state => _state;
  bool get running => _state?.running ?? false;
  bool get cancelRequested => _cancelRequested;

  /// `build` recibe la función de cancelación que el servicio debe consultar.
  bool start(SyncKind kind, Stream<SyncProgress> Function(bool Function() isCancelled) build) {
    if (running) return false;
    _cancelRequested = false;
    final state = SyncRunState(kind);
    _state = state;
    notifyListeners();
    build(() => _cancelRequested).listen(
      (p) {
        state.apply(p);
        notifyListeners();
      },
      onError: (Object e) {
        state.failUnexpected(e);
        _finish();
      },
      onDone: () {
        state.running = false;
        _finish();
      },
      cancelOnError: true,
    );
    return true;
  }

  void cancel() {
    if (!running || _cancelRequested) return;
    _cancelRequested = true;
    notifyListeners();
  }

  /// Oculta el resultado de la última corrida.
  void clear() {
    if (running) return;
    _state = null;
    notifyListeners();
  }

  void _finish() {
    finishedRuns++;
    notifyListeners();
  }
}
