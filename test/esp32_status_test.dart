import 'package:brumaire_mobile/services/error_messages.dart';
import 'package:brumaire_mobile/services/esp32_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Cliente falso: `responder` decide la respuesta de cada request.
Esp32Service fakeEsp(Future<http.Response> Function(http.Request) responder) =>
    Esp32Service(staHost: 'esp32cam.local', client: MockClient(responder));

const okList = '{"files":[],"count":0,"truncated":false}';

void main() {
  group('clasificación de GET /list (contrato esp32-http)', () {
    test('códigos y cuerpos', () {
      expect(Esp32Service.classifyList(200, okList), Esp32Status.conectado);
      expect(Esp32Service.classifyList(500, 'Failed to open Dir'), Esp32Status.sdNoResponde);
      expect(Esp32Service.classifyList(500, 'SD Busy (503)'), Esp32Status.sdOcupada);
      expect(Esp32Service.classifyList(403, 'Only STA mode for this mode'), Esp32Status.modoAp);
    });

    test('checkStatus: SD caída = conectado pero con SD que no responde', () async {
      final h = await fakeEsp((_) async => http.Response('Failed to open Dir', 500)).checkStatus();
      expect(h.status, Esp32Status.sdNoResponde);
      expect(h.status.reachable, isTrue);
      expect(h.technical, contains('Failed to open Dir'));
    });

    test('checkStatus: sin respuesta = no encontrado', () async {
      final h = await fakeEsp((_) async => throw http.ClientException('Failed host lookup'))
          .checkStatus();
      expect(h.status, Esp32Status.noEncontrado);
      expect(h.technical, contains('Failed host lookup'));
    });

    test('listFilesPage lanza Esp32HttpException tipada y ErrorMessages la explica', () async {
      Object? error;
      try {
        await fakeEsp((_) async => http.Response('Failed to open Dir', 500)).listFilesPage();
      } catch (e) {
        error = e;
      }
      expect(error, isA<Esp32HttpException>());
      expect((error as Esp32HttpException).isSdFailure, isTrue);
      expect('$error', 'GET /list falló: 500 (Failed to open Dir)');
      final msg = ErrorMessages.esp32(error);
      expect(msg, contains('SD no responde'));
      expect(msg, contains('Reinicia la placa'));
      expect(ErrorMessages.esp32(const Esp32HttpException('GET /list', 500, 'SD Busy (503)')),
          contains('ocupada'));
    });

    test('404 en log.txt es normal (null)', () async {
      final esp = fakeEsp((_) async => http.Response('File not found', 404));
      expect(await esp.tryDownloadFile('log.txt'), isNull);
    });
  });

  group('POST /reboot', () {
    test('200 es éxito y va al host configurado', () async {
      late http.Request req;
      await fakeEsp((r) async {
        req = r;
        return http.Response('{"status":"reiniciando"}', 200);
      }).reboot();
      expect(req.method, 'POST');
      expect(req.url.toString(), 'http://esp32cam.local/reboot');
    });

    test('conexión cerrada justo después también es éxito', () async {
      await fakeEsp((_) async =>
              throw http.ClientException('Connection closed before full header was received'))
          .reboot();
    });

    test('404 (firmware sin /reboot) es error', () async {
      expect(fakeEsp((_) async => http.Response('Not found', 404)).reboot(),
          throwsA(isA<Esp32HttpException>()));
    });
  });

  group('rebootAndWait', () {
    late DateTime clock;
    late List<Duration> waits;
    setUp(() {
      clock = DateTime(2026);
      waits = [];
    });
    Future<void> fakeDelay(Duration d) async {
      waits.add(d);
      clock = clock.add(d);
    }

    /// /reboot responde 200; los /list siguientes salen de `lists` en orden
    /// (null = sin respuesta); al agotarse se repite el último.
    Esp32Service esp(List<http.Response?> lists) {
      var i = 0;
      return fakeEsp((r) async {
        if (r.url.path == '/reboot') return http.Response('{"status":"reiniciando"}', 200);
        final resp = lists[i < lists.length ? i : lists.length - 1];
        i++;
        if (resp == null) throw http.ClientException('Connection refused');
        return resp;
      });
    }

    Future<RebootResult> run(Esp32Service e, List<String> progress) => e.rebootAndWait(
          delay: fakeDelay,
          now: () => clock,
          onProgress: progress.add,
        );

    test('vuelve con SD OK', () async {
      final progress = <String>[];
      final r = await run(esp([null, null, http.Response(okList, 200)]), progress);
      expect(r.outcome, RebootOutcome.ok);
      expect(r.message, 'ESP32 reiniciado, SD OK.');
      expect(r.status, Esp32Status.conectado);
      expect(waits.first, const Duration(seconds: 3)); // espera inicial
      expect(waits.skip(1), everyElement(const Duration(seconds: 2)));
      expect(progress.any((m) => m.contains('esperando que el ESP32 vuelva')), isTrue);
    });

    test('vuelve pero la SD sigue sin responder', () async {
      final r = await run(esp([null, http.Response('Failed to open Dir', 500)]), []);
      expect(r.outcome, RebootOutcome.sdNoResponde);
      expect(r.message, contains('la SD sigue sin responder'));
      expect(r.status, Esp32Status.sdNoResponde);
    });

    test('SD ocupada es transitoria: sigue esperando', () async {
      final r = await run(
          esp([http.Response('SD Busy (503)', 500), http.Response(okList, 200)]), []);
      expect(r.outcome, RebootOutcome.ok);
    });

    test('no vuelve en 30 s', () async {
      final r = await run(esp([null]), []);
      expect(r.outcome, RebootOutcome.noVolvio);
      expect(r.message, contains('no volvió a conectarse en 30 s'));
      final total = waits.fold(Duration.zero, (a, b) => a + b);
      expect(total, lessThanOrEqualTo(const Duration(seconds: 30)));
      expect(total, greaterThanOrEqualTo(const Duration(seconds: 27)));
    });

    test('firmware sin /reboot: fallo explicado', () async {
      final e = fakeEsp((r) async => r.url.path == '/reboot'
          ? http.Response('Not found', 404)
          : http.Response(okList, 200));
      final r = await e.rebootAndWait(delay: fakeDelay, now: () => clock);
      expect(r.outcome, RebootOutcome.fallo);
      expect(r.message, contains('no aceptó'));
      expect(r.technical, contains('404'));
    });
  });
}
