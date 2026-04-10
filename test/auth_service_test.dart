import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cobblehype_launcher/services/auth_service.dart';
import 'package:cobblehype_launcher/models/minecraft_account.dart';

/// Mock do FlutterSecureStorage para ambiente de teste.
/// Armazena tudo em memória — sem Keychain/DPAPI/Keystore.
void _mockSecureStorage() {
  final storage = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (MethodCall call) async {
      switch (call.method) {
        case 'write':
          final args = call.arguments as Map;
          storage[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          final args = call.arguments as Map;
          return storage[args['key'] as String];
        case 'delete':
          final args = call.arguments as Map;
          storage.remove(args['key'] as String);
          return null;
        case 'readAll':
          return storage;
        case 'deleteAll':
          storage.clear();
          return null;
        default:
          return null;
      }
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockSecureStorage();
  });

  group('AuthService — Login offline', () {
    late AuthService auth;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      auth = AuthService();
    });

    test('loginOffline cria conta válida', () async {
      final account = await auth.loginOffline('TestPlayer');
      expect(account.username, 'TestPlayer');
      expect(account.isOffline, true);
      expect(account.uuid, isNotEmpty);
      expect(account.accessToken, isNotEmpty);
      expect(account.isExpired, false);
    });

    test('loginOffline gera UUID v3 determinístico', () async {
      final a = await auth.loginOffline('Steve');
      final b = await auth.loginOffline('Steve');
      expect(a.uuid, b.uuid);
    });

    test('loginOffline gera UUIDs diferentes para nicks diferentes', () async {
      final a = await auth.loginOffline('Steve');
      final b = await auth.loginOffline('Alex');
      expect(a.uuid, isNot(b.uuid));
    });

    test('loginOffline rejeita nick curto', () async {
      expect(
        () => auth.loginOffline('AB'),
        throwsA(isA<AuthException>()),
      );
    });

    test('loginOffline rejeita nick longo (>16 chars)', () async {
      expect(
        () => auth.loginOffline('A' * 17),
        throwsA(isA<AuthException>()),
      );
    });

    test('loginOffline rejeita caracteres especiais', () async {
      expect(() => auth.loginOffline('user name'), throwsA(isA<AuthException>()));
      expect(() => auth.loginOffline('user@name'), throwsA(isA<AuthException>()));
      expect(() => auth.loginOffline('user<script>'), throwsA(isA<AuthException>()));
    });

    test('loginOffline aceita underscore', () async {
      final account = await auth.loginOffline('Cool_Player');
      expect(account.username, 'Cool_Player');
    });

    test('loginOffline trim em espaços', () async {
      final account = await auth.loginOffline('  Player  ');
      expect(account.username, 'Player');
    });
  });

  group('AuthService — loadSavedAccount', () {
    late AuthService auth;

    test('retorna null sem conta salva', () async {
      SharedPreferences.setMockInitialValues({});
      auth = AuthService();
      final account = await auth.loadSavedAccount();
      expect(account, isNull);
    });
  });

  group('MinecraftAccount', () {
    test('isExpired funciona para conta expirada', () {
      final account = MinecraftAccount(
        username: 'Test',
        uuid: '00000000-0000-0000-0000-000000000000',
        accessToken: 'token',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        isOffline: false,
      );
      expect(account.isExpired, true);
    });

    test('isExpired retorna false para conta válida', () {
      final account = MinecraftAccount(
        username: 'Test',
        uuid: '00000000-0000-0000-0000-000000000000',
        accessToken: 'token',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        isOffline: false,
      );
      expect(account.isExpired, false);
    });

    test('conta offline nunca expira', () {
      final account = MinecraftAccount(
        username: 'Offline',
        uuid: '00000000-0000-0000-0000-000000000000',
        accessToken: 'token',
        expiresAt: DateTime.now().subtract(const Duration(days: 365)),
        isOffline: true,
      );
      expect(account.isExpired, false);
    });

    test('skinHeadUrl usa UUID para conta online', () {
      final account = MinecraftAccount(
        username: 'Steve',
        uuid: 'abc-123',
        accessToken: 'x',
        expiresAt: DateTime.now(),
      );
      expect(account.skinHeadUrl, contains('abc-123'));
    });

    test('skinHeadUrl usa username para conta offline', () {
      final account = MinecraftAccount(
        username: 'Steve',
        uuid: '',
        accessToken: 'x',
        expiresAt: DateTime.now(),
        isOffline: true,
      );
      expect(account.skinHeadUrl, contains('Steve'));
    });

    test('toJson e fromJson são simétricos', () {
      final original = MinecraftAccount(
        username: 'TestUser',
        uuid: '12345678-1234-1234-1234-123456789012',
        accessToken: 'my_token_123',
        expiresAt: DateTime(2025, 6, 15),
        isOffline: false,
      );
      final json = original.toJson();
      final restored = MinecraftAccount.fromJson(json);
      expect(restored.username, original.username);
      expect(restored.uuid, original.uuid);
      expect(restored.accessToken, original.accessToken);
      expect(restored.isOffline, original.isOffline);
    });
  });
}
