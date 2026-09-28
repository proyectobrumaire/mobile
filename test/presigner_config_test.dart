import 'package:brumaire_mobile/services/presigner_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PresignerConfig.resolve (prioridad)', () {
    test('sin guardado ni compilado: incompleta (se pide configuración)', () {
      final c = PresignerConfig.resolve(buildUrl: '', buildSecret: '');
      expect(c.isComplete, isFalse);
      expect(c.hasBuildDefaults, isFalse);
      expect(c.usingBuildDefaults, isFalse);
    });

    test('solo compilado: se usa y se marca como incluido en la app', () {
      final c = PresignerConfig.resolve(buildUrl: 'https://build', buildSecret: 'sb');
      expect(c.url, 'https://build');
      expect(c.secret, 'sb');
      expect(c.isComplete, isTrue);
      expect(c.urlFromBuild && c.secretFromBuild, isTrue);
      expect(c.savedUrl, isEmpty); // el diálogo no prellena el compilado
      expect(c.savedSecret, isEmpty);
    });

    test('guardado no vacío manda sobre el compilado', () {
      final c = PresignerConfig.resolve(
          savedUrl: 'https://mia', savedSecret: 'sm', buildUrl: 'https://build', buildSecret: 'sb');
      expect(c.url, 'https://mia');
      expect(c.secret, 'sm');
      expect(c.usingBuildDefaults, isFalse);
      expect(c.hasBuildDefaults, isTrue);
    });

    test('guardado vacío o en blanco cae al compilado, campo por campo', () {
      final c = PresignerConfig.resolve(
          savedUrl: '  ', savedSecret: 'sm', buildUrl: 'https://build', buildSecret: 'sb');
      expect(c.url, 'https://build');
      expect(c.urlFromBuild, isTrue);
      expect(c.secret, 'sm');
      expect(c.secretFromBuild, isFalse);
    });

    test('solo guardado (APK sin valores compilados): comportamiento de siempre', () {
      final c = PresignerConfig.resolve(
          savedUrl: 'https://mia', savedSecret: 'sm', buildUrl: '', buildSecret: '');
      expect(c.isComplete, isTrue);
      expect(c.hasBuildDefaults, isFalse);
    });
  });

  test('load/save/reset con SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    // En los tests no hay --dart-define: sin compilados.
    expect(PresignerConfig.buildSecret, isEmpty);
    expect((await PresignerConfig.load()).isComplete, isFalse);

    await PresignerConfig.save(url: ' https://mia ', secret: 'sm');
    var c = await PresignerConfig.load();
    expect(c.url, 'https://mia');
    expect(c.secret, 'sm');

    // Un campo vacío al guardar no borra el valor existente.
    await PresignerConfig.save(url: '', secret: 'otro');
    c = await PresignerConfig.load();
    expect(c.url, 'https://mia');
    expect(c.secret, 'otro');

    await PresignerConfig.reset();
    c = await PresignerConfig.load();
    expect(c.savedUrl, isEmpty);
    expect(c.isComplete, isFalse);
  });
}
