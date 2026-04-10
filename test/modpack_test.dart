import 'package:flutter_test/flutter_test.dart';
import 'package:cobblehype_launcher/models/modpack.dart';

void main() {
  group('Constantes do modpack', () {
    test('kMinecraftVersion está no formato correto', () {
      expect(RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(kMinecraftVersion), true);
    });

    test('kFabricLoaderVersion está no formato correto', () {
      expect(
          RegExp(r'^\d+\.\d+(\.\d+)?$').hasMatch(kFabricLoaderVersion), true);
    });

    test('kServerAddress não está vazio', () {
      expect(kServerAddress.isNotEmpty, true);
    });

    test('kLauncherName não está vazio', () {
      expect(kLauncherName.isNotEmpty, true);
    });
  });

  group('ModFile', () {
    test('fromJson com dados mínimos', () {
      final mod = ModFile.fromJson({
        'filename': 'test.jar',
        'url': 'https://example.com/test.jar',
        'hashes': {'sha1': 'deadbeef'},
        'size': 512,
      });
      expect(mod.name, 'test.jar');
      expect(mod.size, 512);
    });

    test('fromJson lança em dados inválidos', () {
      expect(
        () => ModFile.fromJson({'filename': 'x', 'url': 'y', 'hashes': {}, 'size': 0}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('ModpackVersion', () {
    test('fromJson com lista de mods vazia', () {
      final v = ModpackVersion.fromJson({
        'id': 'v1',
        'version_number': '1.0.0',
        'name': 'Test',
        'files': [],
      });
      expect(v.files, isEmpty);
      expect(v.versionNumber, '1.0.0');
    });
  });
}
