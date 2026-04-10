import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../models/minecraft_account.dart';
import '../services/auth_service.dart';

/// Dialog que mostra a página de login Microsoft dentro de um WebView
/// embutido no launcher (apenas Windows). Evita abrir o navegador externo.
class WebViewLoginDialog extends StatefulWidget {
  const WebViewLoginDialog({super.key});

  /// Retorna a conta logada ou null se o usuário cancelou.
  static Future<MinecraftAccount?> show(BuildContext context) {
    return showDialog<MinecraftAccount>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const WebViewLoginDialog(),
    );
  }

  /// Verifica se o WebView2 está disponível no sistema
  static bool get isSupported => Platform.isWindows;

  @override
  State<WebViewLoginDialog> createState() => _WebViewLoginDialogState();
}

class _WebViewLoginDialogState extends State<WebViewLoginDialog> {
  final _webviewController = WebviewController();
  final _auth = AuthService();
  bool _initialized = false;
  bool _exchanging = false;
  String _status = '';
  String? _error;

  HttpServer? _server;
  String? _redirectUri;
  String? _codeVerifier;

  @override
  void initState() {
    super.initState();
    _initWebview();
  }

  Future<void> _initWebview() async {
    try {
      // Prepara o OAuth (servidor local + PKCE)
      final auth = await _auth.prepareAuth();
      _server = auth.server;
      _redirectUri = auth.redirectUri;
      _codeVerifier = auth.codeVerifier;

      // Inicializa o WebView
      await _webviewController.initialize();
      await _webviewController.setBackgroundColor(const Color(0xFF0D1520));
      await _webviewController.setPopupWindowPolicy(
          WebviewPopupWindowPolicy.deny);

      // Escuta navegações para capturar o redirect (aceita localhost e 127.0.0.1)
      _webviewController.url.listen((url) {
        if ((url.startsWith('http://localhost:') ||
                url.startsWith('http://127.0.0.1:')) &&
            url.contains('code=')) {
          _onRedirectCaptured(url);
        }
      });

      // Carrega a URL de auth
      await _webviewController.loadUrl(auth.authUrl);

      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _onRedirectCaptured(String url) async {
    if (_exchanging) return;
    // Seta _exchanging ANTES de qualquer await/setState para evitar race condition:
    // o URL listener pode disparar múltiplas vezes antes do setState ser processado.
    _exchanging = true;
    if (mounted) setState(() => _status = 'Autenticando...');

    try {
      // Extrai o code da URL
      final uri = Uri.parse(url);
      final code = uri.queryParameters['code'];
      final error = uri.queryParameters['error'];

      // Fecha o servidor local
      await _server?.close();

      if (code == null) {
        throw AuthException(error ?? 'Login cancelado.');
      }

      // Troca o code pelo token
      final account = await _auth.loginWithMicrosoftCode(
        code: code,
        redirectUri: _redirectUri!,
        codeVerifier: _codeVerifier!,
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );

      if (mounted) Navigator.of(context).pop(account);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _exchanging = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _webviewController.dispose();
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 500,
          height: 620,
          decoration: BoxDecoration(
            color: const Color(0xFF0D1520),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            children: [
              // Barra de título
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline_rounded,
                        size: 15, color: Color(0xFF00C896)),
                    const SizedBox(width: 8),
                    const Text(
                      'login.microsoftonline.com',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const Spacer(),
                    // Botão fechar
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(null),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 16, color: Colors.white54),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Conteúdo
              Expanded(
                child: _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Fechar'),
              ),
            ],
          ),
        ),
      );
    }

    if (_exchanging) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF00C896)),
            const SizedBox(height: 16),
            Text(
              _status,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00C896)),
      );
    }

    return Webview(_webviewController);
  }
}
