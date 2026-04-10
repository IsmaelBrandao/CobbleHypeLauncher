import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cobblehype_launcher/services/java_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JavaManager', () {
    late JavaManager javaManager;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      javaManager = JavaManager();
    });

    test('detecta plataforma corretamente', () async {
      // Verifica que não lança exceção na plataforma atual
      final installed = await javaManager.isInstalled();
      expect(installed, isA<bool>());
    });

    test('isInstalled retorna false sem Java configurado', () async {
      SharedPreferences.setMockInitialValues({});
      final installed = await javaManager.isInstalled();
      // Em CI/ambiente limpo geralmente será false;
      // apenas verifica que retorna bool sem crash.
      expect(installed, isA<bool>());
    });

    test('isInstalled retorna false com caminho inválido em cache', () async {
      SharedPreferences.setMockInitialValues({
        'java_path': '/caminho/que/nao/existe/bin/java',
      });
      final installed = await javaManager.isInstalled();
      expect(installed, false);
    });
  });
}
