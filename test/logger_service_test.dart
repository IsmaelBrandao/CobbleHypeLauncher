import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cobblehype_launcher/services/logger_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoggerService', () {
    test('singleton retorna mesma instância', () {
      final a = LoggerService.instance;
      final b = LoggerService.instance;
      expect(identical(a, b), true);
    });

    test('init não lança exceção', () async {
      // Em plataforma desktop deve funcionar; Android pula silenciosamente
      if (!Platform.isAndroid) {
        await LoggerService.instance.init();
      }
    });

    test('log não lança exceção mesmo sem init', () async {
      // LoggerService degrada graciosamente se _logFile é null
      await LoggerService.instance.info('teste sem init');
      await LoggerService.instance.warn('warn sem init');
      await LoggerService.instance.error('error sem init');
    });
  });
}
