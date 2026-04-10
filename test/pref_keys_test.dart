import 'package:flutter_test/flutter_test.dart';
import 'package:cobblehype_launcher/services/pref_keys.dart';

void main() {
  group('PrefKey', () {
    test('nenhuma chave duplicada', () {
      final keys = PrefKey.values.map((e) => e.key).toList();
      final unique = keys.toSet();
      expect(unique.length, keys.length,
          reason: 'Existem chaves duplicadas no PrefKey');
    });

    test('nenhuma chave vazia', () {
      for (final pk in PrefKey.values) {
        expect(pk.key.isNotEmpty, true,
            reason: '${pk.name} tem chave vazia');
      }
    });

    test('chaves não contêm espaços', () {
      for (final pk in PrefKey.values) {
        expect(pk.key.contains(' '), false,
            reason: '${pk.name} contém espaço: "${pk.key}"');
      }
    });

    test('valores esperados para chaves conhecidas', () {
      expect(PrefKey.username.key, 'minecraft_username');
      expect(PrefKey.uuid.key, 'minecraft_uuid');
      expect(PrefKey.maxRam.key, 'ram_max_mb');
      expect(PrefKey.javaPath.key, 'java_path');
      expect(PrefKey.modpackVersion.key, 'modpack_version');
      expect(PrefKey.locale.key, 'app_locale');
    });
  });
}
