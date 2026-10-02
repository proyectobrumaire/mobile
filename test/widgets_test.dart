import 'package:brumaire_mobile/main.dart';
import 'package:brumaire_mobile/models/event_record.dart';
import 'package:brumaire_mobile/models/sync_progress.dart';
import 'package:brumaire_mobile/screens/settings_screen.dart';
import 'package:brumaire_mobile/widgets/event_timeline.dart';
import 'package:brumaire_mobile/widgets/photo_viewer.dart';
import 'package:brumaire_mobile/widgets/sync_progress_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('SyncProgressView: pasos, barra de lote, problemas y detalle oculto',
      (tester) async {
    final state = SyncRunState(SyncKind.descargaFotos)
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
          kind: SyncKind.descargaFotos, newPhotos: 12, errors: 1)))
      ..running = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: SyncProgressView(state: state))),
    ));
    expect(find.text('Descarga de fotos terminada con errores'), findsOneWidget);
    expect(find.text('12 fotos nuevas, 1 error'), findsOneWidget);
  });

  testWidgets('PhotoViewerScreen: muestra sensores con etiquetas y unidades', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PhotoViewerScreen(photos: [
        ViewerPhoto(
          image: null,
          title: 'Hoy · 08:30:00',
          subtitle: 'Ave detectada · foto 1 de 3',
          status: (text: 'Pendiente de subir', color: Colors.orange, icon: Icons.cloud_upload),
          sensors: const {'T1_K': 24.5, 'P2_K': 128, 'W1_K': double.nan, 'L1_K': 1},
        ),
        const ViewerPhoto(image: null, title: 'otra'),
      ]),
    ));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('Temp. ambiente'), findsOneWidget);
    expect(find.text('24.5 °C'), findsOneWidget);
    expect(find.text('128 / 255 (50 %)'), findsOneWidget);
    expect(find.text('sin lectura'), findsOneWidget);
    expect(find.text('Lluvia'), findsOneWidget);
    expect(find.text('Sí'), findsOneWidget);
    expect(find.byIcon(Icons.water_drop), findsOneWidget);
    expect(find.text('Pendiente de subir'), findsOneWidget);
  });

  testWidgets('Dos botones; «Descargar fotos» abre el diálogo con «Descarga continua» recordada',
      (tester) async {
    SharedPreferences.setMockInitialValues({'esp32_continuous_download': true});
    await tester.pumpWidget(const BrumaireApp());
    await tester.pump();
    expect(find.text('Descargar log'), findsOneWidget);
    expect(find.text('Descargar SD'), findsNothing);
    await tester.tap(find.text('Descargar fotos'));
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
    expect(find.text('Ave detectada'), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);
    await tester.tap(find.text('Reporte periódico'));
    await tester.pumpAndSettle();
    expect(find.text('Temp. ambiente'), findsOneWidget);
    expect(find.text('Código: PERIODIC'), findsOneWidget);
  });

  testWidgets('Visor: subtítulo completo en pantalla angosta con fuente grande', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625; // ~411 dp, como un Samsung A55
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(411, 891), textScaler: TextScaler.linear(1.3)),
      child: MaterialApp(
        home: PhotoViewerScreen(photos: [
          ViewerPhoto(
            image: null,
            title: 'Miércoles 24 de septiembre · 21:36:19',
            subtitle: 'Sin evento registrado · foto 1 de 3',
            status: (text: 'Pendiente de subir', color: Colors.orange, icon: Icons.cloud_upload),
          ),
        ]),
      ),
    ));
    final finder = find.text('Sin evento registrado · foto 1 de 3');
    expect(finder, findsOneWidget);
    // Ocupa todo el ancho del panel (no queda comprimido por la etiqueta de estado).
    expect(tester.getSize(finder).width, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('EventTimeline: tocar un BIRD usa onTapEvent (abre sus fotos), no el detalle',
      (tester) async {
    final t = DateTime.now();
    EventRecord? tapped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EventTimeline(
          days: groupEventsByDay(
              [EventRecord(timestamp: t, event: 'BIRD', sensors: const {'T1_K': 20})],
              eventCategories.toSet()),
          onTapEvent: (_, ev) => tapped = ev,
        ),
      ),
    ));
    await tester.tap(find.text('Ave detectada'));
    await tester.pumpAndSettle();
    expect(tapped?.event, 'BIRD');
    expect(find.text('Código: BIRD'), findsNothing); // no abrió el detalle
  });

  testWidgets('AppBar principal: solo Galería, Eventos y Configuración', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const BrumaireApp());
    await tester.pump();
    final appBarButtons =
        find.descendant(of: find.byType(AppBar), matching: find.byType(IconButton));
    expect(appBarButtons, findsNWidgets(3));
    expect(find.byTooltip('Galería'), findsOneWidget);
    expect(find.byTooltip('Eventos'), findsOneWidget);
    expect(find.byTooltip('Configuración'), findsOneWidget);
    for (final old in ['IP del ESP32', 'Presigner S3', 'Reiniciar ESP32', 'Configurar ESP32']) {
      expect(find.byTooltip(old), findsNothing, reason: old);
    }
    await tester.tap(find.byTooltip('Configuración'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('Configuración: secciones ESP32 y Servidor con las cuatro opciones', (tester) async {
    SharedPreferences.setMockInitialValues({'esp32_host': '192.168.1.50'});
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('ESP32'), findsOneWidget);
    expect(find.text('Servidor'), findsOneWidget);
    final titles = ['Dirección del ESP32', 'Configurar WiFi del ESP32', 'Reiniciar ESP32', 'Presigner S3'];
    for (final t in titles) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    // Orden: dirección, WiFi, reinicio (junto al WiFi), presigner.
    final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('192.168.1.50'), findsOneWidget); // host actual
    expect(find.text('Sin configurar'), findsOneWidget); // tests sin --dart-define
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Reiniciar ESP32')).enabled, isTrue);

    // Abre el diálogo de dirección con el valor actual.
    await tester.tap(find.text('Dirección del ESP32'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '192.168.1.50'), findsOneWidget);
  });
}
