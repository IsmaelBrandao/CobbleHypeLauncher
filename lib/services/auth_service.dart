import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/minecraft_account.dart';
import 'logger_service.dart';
import 'pref_keys.dart';

/// Autenticação Microsoft OAuth 2.0 → Xbox Live → XSTS → Minecraft
///
/// Fluxo principal: Authorization Code com PKCE
/// 1. Abre browser na tela de login Microsoft
/// 2. Após login, redireciona para localhost (servidor local)
/// 3. Captura o authorization code automaticamente
/// 4. Troca por token Xbox Live → XSTS → token Minecraft
class AuthService {
  // Client ID registrado para o CobbleHype Launcher (público, sem client_secret)
  static const String _clientId = 'c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb';

  // Armazenamento seguro para tokens (Keychain no macOS/iOS, Keystore no Android,
  // libsecret/kwallet no Linux, DPAPI no Windows)
  static const _secureStorage = FlutterSecureStorage();
  static const String _scope = 'XboxLive.signin XboxLive.offline_access';

  // Timeout padrão para requests HTTP
  static const Duration _httpTimeout = Duration(seconds: 30);

  // ---------------------------------------------------------------------------
  // Login Microsoft (Authorization Code + PKCE)
  // ---------------------------------------------------------------------------

  /// Gera a URL de autorização e o servidor local para callback.
  /// Retorna (authUrl, redirectUri, codeVerifier, server).
  Future<({String authUrl, String redirectUri, String codeVerifier, HttpServer server})>
      prepareAuth() async {
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    // Usa 127.0.0.1 explícito em vez de "localhost" para evitar ambiguidade
    // de resolução DNS (localhost pode resolver para ::1 em IPv6, mas o server
    // escuta em IPv4 — o redirect nunca chegaria).
    final server = await HttpServer.bind('127.0.0.1', 0);
    final port = server.port;
    final redirectUri = 'http://127.0.0.1:$port';

    final authUrl =
        'https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize'
        '?client_id=$_clientId'
        '&response_type=code'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
        '&scope=${Uri.encodeComponent(_scope)}'
        '&code_challenge=$codeChallenge'
        '&code_challenge_method=S256'
        '&prompt=select_account';

    return (
      authUrl: authUrl,
      redirectUri: redirectUri,
      codeVerifier: codeVerifier,
      server: server,
    );
  }

  /// Abre o browser na tela de login da Microsoft e retorna a conta após auth.
  /// [onStatus] é chamado com mensagens de progresso para a UI.
  Future<MinecraftAccount> loginWithMicrosoft({
    void Function(String status)? onStatus,
  }) async {
    await LoggerService.instance.info('Login Microsoft iniciado');
    // 1. PKCE + servidor local
    onStatus?.call('Abrindo navegador para login...');
    final auth = await prepareAuth();

    // 2. Abre o browser
    final uri = Uri.parse(auth.authUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await auth.server.close();
      throw const AuthException('Não foi possível abrir o navegador.');
    }

    // 3. Aguarda o redirect com o code (timeout de 5 minutos)
    onStatus?.call('Aguardando login no navegador...');
    final code = await _waitForAuthCode(auth.server).timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        auth.server.close();
        throw const AuthException(
            'Tempo limite para login expirou. Tente novamente.');
      },
    );

    // 4. Troca code por token
    return _exchangeCodeForAccount(
      code: code,
      redirectUri: auth.redirectUri,
      codeVerifier: auth.codeVerifier,
      onStatus: onStatus,
    );
  }

  /// Aguarda o redirect do OAuth e extrai o authorization code.
  /// Usado tanto pelo login por browser quanto pelo WebView.
  Future<String> _waitForAuthCode(HttpServer server) async {
    String? code;
    String? error;

    try {
      await for (final request in server) {
        final params = request.uri.queryParameters;
        code = params['code'];
        error = params['error'];

        request.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');

        if (code != null) {
          request.response.write(_successHtml());
        } else {
          // Sanitiza o erro para evitar XSS
          final safeError = _sanitizeHtml(
              params['error_description'] ?? error ?? 'Tente novamente.');
          request.response.write(_errorHtml(safeError));
        }
        await request.response.close();
        break;
      }
    } finally {
      await server.close();
    }

    if (code == null) {
      throw AuthException(error ?? 'Login cancelado.');
    }

    return code;
  }

  /// Login com code já obtido (usado pelo WebView embutido).
  Future<MinecraftAccount> loginWithMicrosoftCode({
    required String code,
    required String redirectUri,
    required String codeVerifier,
    void Function(String status)? onStatus,
  }) {
    return _exchangeCodeForAccount(
      code: code,
      redirectUri: redirectUri,
      codeVerifier: codeVerifier,
      onStatus: onStatus,
    );
  }

  /// Troca o authorization code por uma conta Minecraft completa.
  Future<MinecraftAccount> _exchangeCodeForAccount({
    required String code,
    required String redirectUri,
    required String codeVerifier,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Autenticando com Microsoft...');
    final tokenResponse = await http.post(
      Uri.parse(
          'https://login.microsoftonline.com/consumers/oauth2/v2.0/token'),
      body: {
        'client_id': _clientId,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier,
        'scope': _scope,
      },
    ).timeout(_httpTimeout);

    if (tokenResponse.statusCode != 200) {
      throw AuthException(
          'Falha ao obter token Microsoft (${tokenResponse.statusCode})');
    }

    final tokenJson =
        jsonDecode(tokenResponse.body) as Map<String, dynamic>;
    final msAccessToken = tokenJson['access_token'] as String;
    final msRefreshToken = tokenJson['refresh_token'] as String? ?? '';

    return await _exchangeForMinecraftToken(
      msAccessToken,
      msRefreshToken,
      onStatus: onStatus,
    );
  }

  // ---------------------------------------------------------------------------
  // PKCE helpers
  // ---------------------------------------------------------------------------

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  // ---------------------------------------------------------------------------
  // Token exchange: Microsoft → Xbox Live → XSTS → Minecraft
  // ---------------------------------------------------------------------------

  Future<MinecraftAccount> _exchangeForMinecraftToken(
    String msAccessToken,
    String msRefreshToken, {
    void Function(String status)? onStatus,
  }) async {
    // 1. Xbox Live
    onStatus?.call('Conectando ao Xbox Live...');
    final xblResponse = await http.post(
      Uri.parse('https://user.auth.xboxlive.com/user/authenticate'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'Properties': {
          'AuthMethod': 'RPS',
          'SiteName': 'user.auth.xboxlive.com',
          'RpsTicket': 'd=$msAccessToken',
        },
        'RelyingParty': 'http://auth.xboxlive.com',
        'TokenType': 'JWT',
      }),
    ).timeout(_httpTimeout);

    if (xblResponse.statusCode != 200) {
      throw AuthException(
          'Falha na autenticação Xbox Live (${xblResponse.statusCode})');
    }

    final xblJson = jsonDecode(xblResponse.body) as Map<String, dynamic>;
    final xblToken = xblJson['Token'] as String;
    final xui = xblJson['DisplayClaims']?['xui'];
    if (xui == null || (xui as List).isEmpty) {
      throw const AuthException('Resposta Xbox Live inválida.');
    }
    final userHash = xui.first['uhs'] as String;

    // 2. XSTS
    onStatus?.call('Obtendo token XSTS...');
    final xstsResponse = await http.post(
      Uri.parse('https://xsts.auth.xboxlive.com/xsts/authorize'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'Properties': {
          'SandboxId': 'RETAIL',
          'UserTokens': [xblToken],
        },
        'RelyingParty': 'rp://api.minecraftservices.com/',
        'TokenType': 'JWT',
      }),
    ).timeout(_httpTimeout);

    if (xstsResponse.statusCode != 200) {
      final xstsErr = jsonDecode(xstsResponse.body) as Map<String, dynamic>;
      final xErr = xstsErr['XErr'];
      if (xErr == 2148916233) {
        throw const AuthException(
            'Esta conta Microsoft não possui uma conta Xbox. '
            'Crie uma em xbox.com antes de continuar.');
      }
      if (xErr == 2148916238) {
        throw const AuthException(
            'Conta de menor de idade. Um responsável precisa adicionar '
            'esta conta a uma família Microsoft.');
      }
      throw AuthException('Falha XSTS ($xErr)');
    }

    final xstsJson = jsonDecode(xstsResponse.body) as Map<String, dynamic>;
    final xstsToken = xstsJson['Token'] as String;

    // 3. Token Minecraft
    onStatus?.call('Entrando no Minecraft...');
    final mcResponse = await http.post(
      Uri.parse(
          'https://api.minecraftservices.com/authentication/login_with_xbox'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'identityToken': 'XBL3.0 x=$userHash;$xstsToken',
      }),
    ).timeout(_httpTimeout);

    if (mcResponse.statusCode != 200) {
      throw AuthException(
          'Falha na autenticação Minecraft (${mcResponse.statusCode})');
    }

    final mcJson = jsonDecode(mcResponse.body) as Map<String, dynamic>;
    final mcToken = mcJson['access_token'] as String;
    final expiresIn = mcJson['expires_in'] as int;

    // 4. Perfil do jogador
    onStatus?.call('Carregando perfil...');
    final profileResponse = await http.get(
      Uri.parse('https://api.minecraftservices.com/minecraft/profile'),
      headers: {'Authorization': 'Bearer $mcToken'},
    ).timeout(_httpTimeout);

    if (profileResponse.statusCode != 200) {
      throw const AuthException(
          'Esta conta Microsoft não possui Minecraft Java Edition. '
          'Compre o jogo em minecraft.net.');
    }

    final profileJson =
        jsonDecode(profileResponse.body) as Map<String, dynamic>;

    final account = MinecraftAccount(
      username: profileJson['name'] as String,
      uuid: profileJson['id'] as String,
      accessToken: mcToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );

    await _saveAccount(account, msRefreshToken);
    // Loga username mas nunca o token — dado sensível
    await LoggerService.instance.info('Login Microsoft concluído: ${account.username}');
    return account;
  }

  // ---------------------------------------------------------------------------
  // Refresh token (renova automaticamente quando expirado)
  // ---------------------------------------------------------------------------

  Future<MinecraftAccount?> refreshIfNeeded() async {
    final account = await loadSavedAccount();
    if (account == null || account.isOffline) return account;
    if (!account.isExpired) return account;

    final refreshToken =
        await _secureStorage.read(key: 'ms_refresh_token') ?? '';
    if (refreshToken.isEmpty) return null;

    try {
      final tokenResponse = await http.post(
        Uri.parse(
            'https://login.microsoftonline.com/consumers/oauth2/v2.0/token'),
        body: {
          'client_id': _clientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'scope': _scope,
        },
      ).timeout(_httpTimeout);

      if (tokenResponse.statusCode != 200) return null;

      final tokenJson =
          jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final msAccessToken = tokenJson['access_token'] as String;
      final newRefreshToken =
          tokenJson['refresh_token'] as String? ?? refreshToken;

      return await _exchangeForMinecraftToken(msAccessToken, newRefreshToken);
    } catch (e) {
      await LoggerService.instance.error('Falha ao renovar token Microsoft: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Login offline
  // ---------------------------------------------------------------------------

  Future<MinecraftAccount> loginOffline(String username) async {
    // Valida o username antes de criar a conta
    final sanitized = username.trim();
    if (sanitized.length < 3 || sanitized.length > 16) {
      throw const AuthException('Nick deve ter entre 3 e 16 caracteres.');
    }
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(sanitized)) {
      throw const AuthException('Nick inválido. Use apenas letras, números e _.');
    }

    final uuid = _offlineUUID(sanitized);
    final account = MinecraftAccount(
      username: sanitized,
      uuid: uuid,
      accessToken: _randomToken(),
      expiresAt: DateTime.now().add(const Duration(days: 36500)),
      isOffline: true,
    );
    await _saveAccount(account, '');
    return account;
  }

  /// UUID v3 offline — mesmo algoritmo usado pelo servidor Minecraft
  String _offlineUUID(String username) {
    final bytes = md5.convert(utf8.encode('OfflinePlayer:$username')).bytes;
    final b = List<int>.from(bytes);
    b[6] = (b[6] & 0x0f) | 0x30; // versão 3
    b[8] = (b[8] & 0x3f) | 0x80; // variante RFC 4122
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  String _randomToken() {
    final rng = Random.secure();
    return List.generate(
        32, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ---------------------------------------------------------------------------
  // Persistência
  // ---------------------------------------------------------------------------

  Future<void> _saveAccount(
      MinecraftAccount account, String refreshToken) async {
    // Tokens sensíveis → armazenamento seguro (Keychain/Keystore/DPAPI)
    await _secureStorage.write(
        key: 'minecraft_access_token', value: account.accessToken);
    if (refreshToken.isNotEmpty) {
      await _secureStorage.write(
          key: 'ms_refresh_token', value: refreshToken);
    }

    // Dados não-sensíveis → SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefKey.username.key, account.username);
    await prefs.setString(PrefKey.uuid.key, account.uuid);
    await prefs.setString(
        PrefKey.tokenExpiresAt.key, account.expiresAt.toIso8601String());
    await prefs.setBool(PrefKey.accountIsOffline.key, account.isOffline);
  }

  Future<MinecraftAccount?> loadSavedAccount() async {
    // Token lido do armazenamento seguro
    final token = await _secureStorage.read(key: 'minecraft_access_token');
    if (token == null || token.isEmpty) return null;

    // Dados não-sensíveis do SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(PrefKey.username.key) ?? '';
    if (username.isEmpty) return null;

    return MinecraftAccount(
      username: username,
      uuid: prefs.getString(PrefKey.uuid.key) ?? '',
      accessToken: token,
      expiresAt: DateTime.parse(
          prefs.getString(PrefKey.tokenExpiresAt.key) ??
              DateTime.now().toIso8601String()),
      isOffline: prefs.getBool(PrefKey.accountIsOffline.key) ?? false,
    );
  }

  Future<void> logout() async {
    // Remove tokens do armazenamento seguro
    await _secureStorage.delete(key: 'minecraft_access_token');
    await _secureStorage.delete(key: 'ms_refresh_token');

    // Remove dados não-sensíveis do SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PrefKey.username.key);
    await prefs.remove(PrefKey.uuid.key);
    await prefs.remove(PrefKey.tokenExpiresAt.key);
    await prefs.remove(PrefKey.accountIsOffline.key);
  }

  // ---------------------------------------------------------------------------
  // HTML helpers (sanitizados contra XSS)
  // ---------------------------------------------------------------------------

  static String _sanitizeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _successHtml() => '''
<!DOCTYPE html>
<html><body style="background:#0D1520;color:#fff;font-family:sans-serif;
display:flex;justify-content:center;align-items:center;height:100vh;margin:0">
<div style="text-align:center">
<h2 style="color:#00C896">Login realizado!</h2>
<p>Pode fechar esta aba e voltar ao launcher.</p>
</div></body></html>''';

  static String _errorHtml(String safeMessage) => '''
<!DOCTYPE html>
<html><body style="background:#0D1520;color:#fff;font-family:sans-serif;
display:flex;justify-content:center;align-items:center;height:100vh;margin:0">
<div style="text-align:center">
<h2 style="color:#ff4444">Erro no login</h2>
<p>$safeMessage</p>
</div></body></html>''';
}

/// Exceção específica de autenticação para tratamento na UI
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}
