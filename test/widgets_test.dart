import 'package:brumaire_mobile/main.dart';
import 'package:brumaire_mobile/models/event_record.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/widgets/event_timeline.dart';
import 'package:brumaire_mobile/widgets/photo_viewer.dart';
import 'package:brumaire_mobile/widgets/sync_progress_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('SyncProgressView: pasos, barra de lote, problemas y detalle oculto',
      (tester) async {
    final state = SyncRunState(SyncKind.descarga)
      ..apply(const SyncProgress(SyncStep.conectar, StepStatus.ok, 'Conectado.'))
      ..apply(const SyncProgress(
        SyncStep.fotos,
        StepStatus.enCurso,
        'Lote 2: foto 7 de 20',
        current: 7,
        total: 20,
        overall: '34 fotos descargadas, quedan más en la SD',
        overallOngoing: true,
        issue: SyncIssue('image_x.jpg: El ESP32 no respondió a tiempo.', technical: 'TimeoutException'),
      ));
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncProgressView(state: state, onCancel: () => cancelled = true),
        ),
      ),
    ));
    expect(find.text('7/20'), findsOneWidget);
    expect(find.text('34 fotos descargadas, quedan más en la SD'), findsOneWidget);
    expect(find.text('TimeoutException'), findsNothing);
    await tester.tap(find.text('Ver 1 problema'));
    await tester.pump();
    expect(find.text('TimeoutException'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    expect(cancelled, isTrue);

    state
      ..apply(SyncProgress.done(const SyncSummary(
          kind: SyncKind.descarga, newPhotos: 12, newLines: 240, errors: 1)))
      ..running = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: SyncProgressView(state: state))),
    ));
    expect(find.text('Descarga terminada con errores'), findsOneWidget);
    expect(find.text('12 fotos nuevas, 240 lecturas, 1 error'), findsOneWidget);
  });

  testWidgets('PhotoViewerScreen: muestra sensores con etiquetas y unidades', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PhotoViewerScreen(photos: [
        ViewerPhoto(
          image: null,
          title: 'Hoy · 08:30:00',
          subtitle: 'Ave detectada · foto 1 de 3',
          status: (text: 'Pendiente de subir', color: Colors.orange, icon: Icons.cloud_upload),
          sensors: const {'T1_K': 24.5, 'P2_K': 128, 'W1_K': double.nan},
        ),
        const ViewerPhoto(image: null, title: 'otra'),
      ]),
    ));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Temp. ambiente'), findsOneWidget);
    expect(find.text('24.5 °C'), findsOneWidget);
    expect(find.text('128 / 255 (50 %)'), findsOneWidget);
    expect(find.text('sin lectura'), findsOneWidget);
    expect(find.text('Pendiente de subir'), findsOneWidget);
  });

  testWidgets('Descargar SD abre el diálogo con «Descarga continua» recordada',
      (tester) async {
    SharedPreferences.setMockInitialValues({'esp32_continuous_download': true});
    await tester.pumpWidget(const BrumaireApp());
    await tester.pump();
    await tester.tap(find.text('Descargar SD'));
    await tester.pumpAndSettle();
    expect(find.text('Descarga continua'), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isTrue);
    expect(find.text('Iniciar'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Descarga continua'), findsNothing);
  });

  testWidgets('EventTimeline: días, nombres legibles y detalle con sensores', (tester) async {
    final t = DateTime.now();
    final records = [
      EventRecord(timestamp: t, event: 'PERIODIC', sensors: const {'T1_K': 24.5, 'H1_K': 60}),
      EventRecord(timestamp: t.subtract(const Duration(minutes: 5)), event: 'VOLCADO'),
      EventRecord(timestamp: t, event: 'BIRD'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EventTimeline(days: groupEventsByDay(records, eventCategories.toSet())),
      ),
    ));
    expect(find.text('Hoy'), findsOneWidget);
    expect(find.text('Reporte periódico'), findsOneWidget);
    expect(find.text('Vaciado del plato'), findsOneWidget);
    expect(find.text('Ave detectada'), findsNothing);
    await tester.tap(find.text('Reporte periódico'));
    await tester.pumpAndSettle();
    expect(find.text('Temp. ambiente'), findsOneWidget);
    expect(find.text('Código: PERIODIC'), findsOneWidget);
  });
}
