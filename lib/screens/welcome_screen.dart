import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/locale_provider.dart';
import '../services/pref_keys.dart';
import 'login_screen.dart';

// ─── Particles ────────────────────────────────────────────────────────────────

class _Particle {
  final double x, y, speed, size, opacity;
  const _Particle({required this.x, required this.y, required this.speed, required this.size, required this.opacity});
  factory _Particle.random(Random rng) => _Particle(
        x: rng.nextDouble(), y: rng.nextDouble(),
        speed: 0.010 + rng.nextDouble() * 0.018,
        size: 1.4 + rng.nextDouble() * 2.0,
        opacity: 0.18 + rng.nextDouble() * 0.32,
      );
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double time;
  const _ParticlePainter({required this.particles, required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final y = ((p.y - p.speed * time * 20) % 1.0 + 1.0) % 1.0;
      final dx = p.x * size.width;
      final dy = y * size.height;
      canvas.drawCircle(Offset(dx, dy), p.size * 3.5,
          Paint()..color = const Color(0xFFB8FFE0).withValues(alpha: p.opacity * 0.10)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawCircle(Offset(dx, dy), p.size,
          Paint()..color = const Color(0xFFB8FFE0).withValues(alpha: p.opacity));
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.time != time;
}

// ─── WelcomeScreen ────────────────────────────────────────────────────────────

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _particleCtrl;
  late final AnimationController _fadeCtrl;
  late final List<_Particle> _particles;
  final _rng = Random();

  static const _accent = Color(0xFF00C896);
  static const _accentLight = Color(0xFF00E6A8);

  @override
  void initState() {
    super.initState();

    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();

    // Fade-in suave do conteúdo ao abrir a tela
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    _particles = List.generate(20, (_) => _Particle.random(_rng));
  }

  @override
  void dispose() {
    _particleCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    // Marca onboarding como concluído
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(PrefKey.onboardingDone.key, true);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = sOf(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fundo
          Image.asset(
            'assets/images/background.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(color: const Color(0xFF071410)),
          ),

          // Gradiente escuro — mais denso no centro pra destacar o conteúdo
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.0,
                colors: [
                  Color(0x99000000), // centro: 60% black
                  Color(0xCC000000), // borda: 80% black
                ],
              ),
            ),
          ),

          // Partículas
          AnimatedBuilder(
            animation: _particleCtrl,
            builder: (_, __) => CustomPaint(
              painter: _ParticlePainter(particles: _particles, time: _particleCtrl.value),
              child: const SizedBox.expand(),
            ),
          ),

          // Conteúdo com fade-in
          FadeTransition(
            opacity: CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut),
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Logo — destaque central
                        Image.asset(
                          'assets/images/logo2.png',
                          width: 160,
                          height: 160,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.grass_rounded,
                            color: Colors.white54,
                            size: 64,
                          ),
                        ),

                        const SizedBox(height: 32),

                        // Título com gradiente
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [Colors.white, Color(0xFFB0FFE0)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ).createShader(bounds),
                          child: Text(
                            s.welcomeTitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Linha divisória com gradiente
                        Container(
                          width: 60,
                          height: 2,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                _accent.withValues(alpha: 0.7),
                                Colors.transparent,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Descrição
                        Text(
                          s.welcomeBody,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.58),
                            fontSize: 14.5,
                            height: 1.65,
                          ),
                        ),

                        const SizedBox(height: 48),

                        // Botão CONTINUAR
                        _ContinueButton(
                          label: s.welcomeContinue,
                          onTap: _continue,
                          accent: _accent,
                          accentLight: _accentLight,
                        ),

                        const SizedBox(height: 32),

                        Text(
                          'CobbleHype · Fabric 1.21.1',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.20),
                            letterSpacing: 0.5,
                          ),
                        ),
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
}

// ─── _ContinueButton ─────────────────────────────────────────────────────────

class _ContinueButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color accent;
  final Color accentLight;

  const _ContinueButton({
    required this.label,
    required this.onTap,
    required this.accent,
    required this.accentLight,
  });

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
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
          width: 240,
          height: 52,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _hovered
                  ? [widget.accentLight, widget.accent]
                  : [widget.accent, const Color(0xFF00A87A)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: widget.accent.withValues(alpha: _hovered ? 0.50 : 0.22),
                blurRadius: _hovered ? 28 : 12,
                spreadRadius: _hovered ? 2 : 0,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.82),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.5,
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.arrow_forward_rounded,
                color: Colors.black.withValues(alpha: 0.75),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
