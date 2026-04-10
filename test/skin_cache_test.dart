import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

/// Testa a lógica de hash que o SkinCache usa para gerar nomes de arquivo.
/// Não testa I/O real (requer path_provider) — só a lógica pura.
void main() {
  group('SkinCache — lógica de hash', () {
    String urlToFileName(String url) {
      final bytes = utf8.encode(url);
      final digest = md5.convert(bytes);
      return 'skin_$digest.png';
    }

    test('hash é determinístico', () {
      const url = 'https://mc-heads.net/head/Steve/128';
      expect(urlToFileName(url), urlToFileName(url));
    });

    test('URLs diferentes geram hashes diferentes', () {
      final a = urlToFileName('https://mc-heads.net/head/Steve/128');
      final b = urlToFileName('https://mc-heads.net/head/Alex/128');
      expect(a, isNot(b));
    });

    test('formato do nome é skin_{md5}.png', () {
      final name = urlToFileName('https://example.com/skin.png');
      expect(name, matches(RegExp(r'^skin_[0-9a-f]{32}\.png$')));
    });
  });
}
