import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../l10n/locale_provider.dart';
import '../services/auth_service.dart';
import 'home_screen.dart';
import 'webview_login_dialog.dart';

// ─── Particle system ─────────────────────────────────────────────────────────

class _Particle {
  final double x;
  final double y;
  final double speed;
  final double size;
  final double opacity;

  const _Particle({
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
    required this.opacity,
  });

  factory _Particle.random(Random rng) => _Particle(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        speed: 0.015 + rng.nextDouble() * 0.025,
        size: 1.5 + rng.nextDouble() * 2.0,
        opacity: 0.2 + rng.nextDouble() * 0.35,
      );
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double time;
  final Paint _glowPaint;
  final Paint _dotPaint;

  _ParticlePainter({required this.particles, required this.time})
      : _glowPaint = Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        _dotPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final y = ((p.y - p.speed * time * 20) % 1.0 + 1.0) % 1.0;
      final dx = p.x * size.width;
      final dy = y * size.height;

      canvas.drawCircle(
        Offset(dx, dy),
        p.size * 3.5,
        _glowPaint
          ..color = const Color(0xFFB8FFE0).withValues(alpha: p.opacity * 0.12),
      );

      canvas.drawCircle(
        Offset(dx, dy),
        p.size,
        _dotPaint
          ..color = const Color(0xFFB8FFE0).withValues(alpha: p.opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.time != time;
}

// ─── Login Screen ─────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _auth = AuthService();

  // Strings traduzidas — atualizado em didChangeDependencies
  late S _s;

  // Microsoft
  bool _msLoading = false;
  String _msStatus = '';

  // Offline
  final _nickController = TextEditingController();
  bool _offlineLoading = false;
  String _offlineError = '';
  bool _showOfflineForm = false;

  // Partículas
  late final AnimationController _particleCtrl;
  late final List<_Particle> _particles;
  final _rng = Random();

  static const Color _accent = Color(0xFF00C896);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s = sOf(context);
  }

  @override
  void initState() {
    _s = const S(AppLocale.ptBR); // default antes do primeiro didChangeDependencies
    super.initState();
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _particles = List.generate(28, (_) => _Particle.random(_rng));
  }

  @override
  void dispose() {
    _particleCtrl.dispose();
    _nickController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Microsoft login
  // ---------------------------------------------------------------------------

  Future<void> _startMicrosoftLogin() async {
    // Windows: usa WebView embutido (como Helios Launcher)
    if (Platform.isWindows && WebViewLoginDialog.isSupported) {
      final account = await WebViewLoginDialog.show(context);
      if (account != null && mounted) {
        _goHome();
      }
      return;
    }

    // Outras plataformas: abre navegador externo
    setState(() {
      _msLoading = true;
      _msStatus = _s.loginStarting;
    });

    try {
      await _auth.loginWithMicrosoft(
        onStatus: (status) {
          if (mounted) setState(() => _msStatus = status);
        },
      );
      if (!mounted) return;
      _goHome();
    } catch (e) {
      if (mounted) {
        setState(() {
          _msStatus = '';
          _msLoading = false;
        });
        _showError(e.toString(), onRetry: _startMicrosoftLogin);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Modal de erro customizado — glassmorphism + accent
  // ---------------------------------------------------------------------------

  void _showError(String message, {VoidCallback? onRetry}) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Fechar',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (_, anim, __, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: CurvedAnimation(
              parent: anim,
              curve: Curves.easeOutBack,
            ),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, _, __) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1117).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.3),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.redAccent.withValues(alpha: 0.08),
                          blurRadius: 30,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header com ícone
                            Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.error_outline_rounded,
                                    color: Colors.redAccent,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _s.loginErrorTitle,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),

                            // Divider sutil
                            Container(
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.06),
                            ),

                            const SizedBox(height: 16),

                            // Mensagem
                            Text(
                              message,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.72),
                                fontSize: 13.5,
                                height: 1.5,
                              ),
                            ),

                            const SizedBox(height: 24),

                            // Botões: OK (sempre) + Tentar novamente (se onRetry fornecido)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _GlowTextButton(
                                  label: _s.loginErrorOk,
                                  color: Colors.white30,
                                  onTap: () => Navigator.pop(ctx),
                                ),
                                if (onRetry != null) ...[
                                  const SizedBox(width: 12),
                                  _GlowTextButton(
                                    label: _s.retryAction,
                                    color: Colors.redAccent,
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      onRetry();
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Offline login
  // ---------------------------------------------------------------------------

  Future<void> _loginOffline() async {
    final nick = _nickController.text.trim();

    if (nick.isEmpty) {
      setState(() => _offlineError = _s.loginNickEmpty);
      return;
    }
    if (nick.length < 3 || nick.length > 16) {
      setState(() => _offlineError = _s.loginNickLength);
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(nick)) {
      setState(
          () => _offlineError = _s.loginNickInvalid);
      return;
    }

    setState(() {
      _offlineLoading = true;
      _offlineError = '';
    });

    await _auth.loginOffline(nick);
    if (!mounted) return;
    _goHome();
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Imagem de fundo
          Image.asset(
            'assets/images/background.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                Container(color: const Color(0xFF0A1A0E)),
          ),

          // 2. Overlay escuro
          Container(color: Colors.black.withValues(alpha: 0.52)),

          // 3. Partículas animadas
          AnimatedBuilder(
            animation: _particleCtrl,
            builder: (_, __) => CustomPaint(
              painter: _ParticlePainter(
                particles: _particles,
                time: _particleCtrl.value,
              ),
              child: const SizedBox.expand(),
            ),
          ),

          // 4. Conteúdo centralizado
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildTitle(),
                        const SizedBox(height: 40),
                        _buildMicrosoftButton(),
                        const SizedBox(height: 14),
                        _buildOfflineButton(),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeInOut,
                          child: _showOfflineForm
                              ? _buildOfflineForm()
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 32),
                        _buildFooter(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Titulo
  // ---------------------------------------------------------------------------

  Widget _buildTitle() {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFFFFFFFF), Color(0xFFB0B8C0)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(bounds),
      child: Text(
        _s.loginTitle,
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Botao Microsoft — primario, com gradiente verde
  // ---------------------------------------------------------------------------

  Widget _buildMicrosoftButton() {
    return _HoverLoginButton(
      onPressed: _msLoading ? null : _startMicrosoftLogin,
      loading: _msLoading,
      loadingLabel: _msStatus.isNotEmpty ? _msStatus : _s.loginWaiting,
      icon: const FaIcon(FontAwesomeIcons.microsoft, size: 18, color: Colors.white),
      label: _s.loginMicrosoft,
      isPrimary: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Botao Offline — secundario
  // ---------------------------------------------------------------------------

  Widget _buildOfflineButton() {
    return _HoverLoginButton(
      onPressed: () => setState(() => _showOfflineForm = !_showOfflineForm),
      loading: false,
      loadingLabel: '',
      icon: const Icon(Icons.person_outline_rounded, size: 20, color: Colors.white70),
      label: _s.loginOfflineBtn,
      isPrimary: false,
      isActive: _showOfflineForm,
    );
  }

  // ---------------------------------------------------------------------------
  // Formulario offline expandivel
  // ---------------------------------------------------------------------------

  Widget _buildOfflineForm() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Nick TextField
          TextField(
            controller: _nickController,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            maxLength: 16,
            autofocus: true,
            onSubmitted: (_) => _loginOffline(),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
            ],
            decoration: InputDecoration(
              hintText: _s.loginNickHint,
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.30),
                fontSize: 14,
              ),
              prefixIcon: Icon(
                Icons.alternate_email_rounded,
                color: Colors.white.withValues(alpha: 0.30),
                size: 18,
              ),
              filled: true,
              fillColor: const Color(0xFF0D1117).withValues(alpha: 0.7),
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _accent, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.redAccent),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: Colors.redAccent, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              errorText: _offlineError.isEmpty ? null : _offlineError,
              errorStyle: const TextStyle(
                color: Colors.redAccent,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Botao Jogar Offline
          _HoverPlayOfflineButton(
            onPressed: _offlineLoading ? null : _loginOffline,
            loading: _offlineLoading,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Rodape
  // ---------------------------------------------------------------------------

  Widget _buildFooter() {
    return Text(
      _s.loginFooter,
      style: TextStyle(
        fontSize: 11,
        color: Colors.white.withValues(alpha: 0.22),
        letterSpacing: 0.5,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widgets auxiliares
// ═══════════════════════════════════════════════════════════════════════════════

// ─── _GlowTextButton ─────────────────────────────────────────────────────────
// Botaozinho de texto com glow sutil — usado no modal de erro

class _GlowTextButton extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GlowTextButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_GlowTextButton> createState() => _GlowTextButtonState();
}

class _GlowTextButtonState extends State<_GlowTextButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? widget.color.withValues(alpha: 0.15)
                : widget.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.color.withValues(alpha: _hovered ? 0.5 : 0.25),
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── _HoverLoginButton ───────────────────────────────────────────────────────
// Botao principal de login com hover, gradiente e glow

class _HoverLoginButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final String loadingLabel;
  final Widget icon;
  final String label;
  final bool isPrimary;
  final bool isActive;

  const _HoverLoginButton({
    required this.onPressed,
    required this.loading,
    required this.loadingLabel,
    required this.icon,
    required this.label,
    this.isPrimary = false,
    this.isActive = false,
  });

  @override
  State<_HoverLoginButton> createState() => _HoverLoginButtonState();
}

class _HoverLoginButtonState extends State<_HoverLoginButton> {
  static const Color _accent = Color(0xFF00C896);
  static const Color _accentLight = Color(0xFF00E6A8);
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool primary = widget.isPrimary;
    final bool hovered = _hovered && widget.onPressed != null;
    final bool active = widget.isActive;

    // Cores de borda e fundo variam por estado
    final borderColor = primary
        ? (hovered ? _accentLight.withValues(alpha: 0.6) : _accent.withValues(alpha: 0.35))
        : (hovered || active
            ? Colors.white.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.10));

    final bgColor = primary
        ? (hovered
            ? _accent.withValues(alpha: 0.15)
            : _accent.withValues(alpha: 0.06))
        : (hovered
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.03));

    final glowColor = primary
        ? _accent.withValues(alpha: hovered ? 0.20 : 0.08)
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          height: 56,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1.2),
            boxShadow: [
              if (primary)
                BoxShadow(
                  color: glowColor,
                  blurRadius: hovered ? 28 : 12,
                  spreadRadius: hovered ? 1 : 0,
                ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                // Gradiente sutil no fundo do botao primario
                if (primary)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: hovered ? 1.0 : 0.0,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              _accent.withValues(alpha: 0.08),
                              _accentLight.withValues(alpha: 0.03),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Conteudo
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icone ou spinner
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: widget.loading
                            ? SizedBox(
                                key: const ValueKey('spinner'),
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: primary ? _accent : Colors.white54,
                                ),
                              )
                            : SizedBox(
                                key: const ValueKey('icon'),
                                width: 24,
                                child: widget.icon,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        widget.loading ? widget.loadingLabel : widget.label,
                        style: TextStyle(
                          color: primary
                              ? (hovered ? _accentLight : Colors.white)
                              : Colors.white.withValues(alpha: 0.75),
                          fontSize: 15,
                          fontWeight: primary ? FontWeight.w700 : FontWeight.w500,
                          letterSpacing: primary ? 0.5 : 0.3,
                        ),
                      ),
                    ],
                  ),
                ),

                // Linha de accent no topo do botao primario
                if (primary)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            _accent.withValues(alpha: hovered ? 0.7 : 0.3),
                            _accentLight.withValues(alpha: hovered ? 0.7 : 0.3),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.3, 0.7, 1.0],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── _HoverPlayOfflineButton ─────────────────────────────────────────────────
// Botao "Jogar Offline" do formulario — compacto, com gradiente verde

class _HoverPlayOfflineButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool loading;

  const _HoverPlayOfflineButton({
    required this.onPressed,
    this.loading = false,
  });

  @override
  State<_HoverPlayOfflineButton> createState() =>
      _HoverPlayOfflineButtonState();
}

class _HoverPlayOfflineButtonState extends State<_HoverPlayOfflineButton> {
  static const Color _green = Color(0xFF00C896);
  static const Color _greenLight = Color(0xFF00E6A8);
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool hovered = _hovered && widget.onPressed != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: hovered
                  ? [_greenLight, _green]
                  : [_green, const Color(0xFF00A87A)],
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: _green.withValues(alpha: hovered ? 0.40 : 0.18),
                blurRadius: hovered ? 20 : 8,
                spreadRadius: hovered ? 1 : 0,
              ),
            ],
          ),
          child: Center(
            child: widget.loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black54,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.black.withValues(alpha: 0.75),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        sOf(context).loginPlayOffline,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.80),
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
