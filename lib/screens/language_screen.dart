import 'dart:math';

import 'package:flutter/material.dart';

import '../l10n/locale_provider.dart';
import 'welcome_screen.dart';

// ─── Particles ────────────────────────────────────────────────────────────────

class _Particle {
  final double x, y, speed, size, opacity;
  const _Particle({required this.x, required this.y, required this.speed, required this.size, required this.opacity});
  factory _Particle.random(Random rng) => _Particle(
        x: rng.nextDouble(), y: rng.nextDouble(),
        speed: 0.012 + rng.nextDouble() * 0.02,
        size: 1.2 + rng.nextDouble() * 1.8,
        opacity: 0.15 + rng.nextDouble() * 0.30,
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

// ─── LanguageScreen ───────────────────────────────────────────────────────────

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> with TickerProviderStateMixin {
  AppLocale _selected = AppLocale.ptBR;

  late final AnimationController _particleCtrl;
  late final List<_Particle> _particles;
  final _rng = Random();

  static const _accent = Color(0xFF00C896);
  static const _accentLight = Color(0xFF00E6A8);

  @override
  void initState() {
    super.initState();
    // Pre-seleciona o locale já salvo (se existir)
    final provider = LocaleProvider.maybeOf(context);
    if (provider != null) _selected = provider.locale;

    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
    _particles = List.generate(18, (_) => _Particle.random(_rng));
  }

  @override
  void dispose() {
    _particleCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    await LocaleProvider.maybeOf(context)?.setLocale(_selected);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Usa a linguagem selecionada para preview imediato, sem esperar o provider
    final s = S(_selected);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fundo
          Image.asset('assets/images/background.png', fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: const Color(0xFF071410))),
          Container(color: Colors.black.withValues(alpha: 0.58)),

          // Partículas
          AnimatedBuilder(
            animation: _particleCtrl,
            builder: (_, __) => CustomPaint(
              painter: _ParticlePainter(particles: _particles, time: _particleCtrl.value),
              child: const SizedBox.expand(),
            ),
          ),

          // Conteúdo
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Logo
                        Image.asset(
                          'assets/images/logo2.png',
                          width: 68, height: 68,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.grass_rounded, color: Colors.white54, size: 48),
                        ),
                        const SizedBox(height: 28),

                        // Título (muda com o idioma selecionado)
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            s.langTitle,
                            key: ValueKey(_selected),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            s.langSubtitle,
                            key: ValueKey('sub_$_selected'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.42),
                              fontSize: 13,
                            ),
                          ),
                        ),

                        const SizedBox(height: 40),

                        // Cards de idioma
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (int i = 0; i < AppLocale.values.length; i++) ...[
                              if (i > 0) const SizedBox(width: 12),
                              Expanded(
                                child: _LanguageCard(
                                  locale: AppLocale.values[i],
                                  selected: _selected == AppLocale.values[i],
                                  onTap: () => setState(() => _selected = AppLocale.values[i]),
                                ),
                              ),
                            ],
                          ],
                        ),

                        const SizedBox(height: 40),

                        // Botão confirmar
                        _ConfirmButton(
                          label: s.langConfirm,
                          onTap: _confirm,
                          accent: _accent,
                          accentLight: _accentLight,
                        ),

                        const SizedBox(height: 28),
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

// ─── _LanguageCard ────────────────────────────────────────────────────────────

class _LanguageCard extends StatefulWidget {
  final AppLocale locale;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageCard({
    required this.locale,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_LanguageCard> createState() => _LanguageCardState();
}

class _LanguageCardState extends State<_LanguageCard> {
  static const _accent = Color(0xFF00C896);
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final hovered = _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 118,
          decoration: BoxDecoration(
            color: selected
                ? _accent.withValues(alpha: 0.10)
                : hovered
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? _accent.withValues(alpha: 0.60)
                  : hovered
                      ? Colors.white.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.08),
              width: selected ? 1.5 : 1.0,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: _accent.withValues(alpha: 0.12),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                  ]
                : [],
          ),
          child: Stack(
            children: [
              // Checkmark quando selecionado
              if (selected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      color: _accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded, size: 12, color: Colors.black),
                  ),
                ),

              // Conteúdo centralizado
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Flag emoji
                    Text(
                      widget.locale.flag,
                      style: const TextStyle(fontSize: 34),
                    ),
                    const SizedBox(height: 10),
                    // Nome do idioma
                    Text(
                      widget.locale.displayName.split(' ').first, // "Português", "English", "Español"
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.80),
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    // Sufixo (BR)
                    if (widget.locale == AppLocale.ptBR) ...[
                      const SizedBox(height: 2),
                      Text(
                        '(BR)',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── _ConfirmButton ───────────────────────────────────────────────────────────

class _ConfirmButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color accent;
  final Color accentLight;

  const _ConfirmButton({
    required this.label,
    required this.onTap,
    required this.accent,
    required this.accentLight,
  });

  @override
  State<_ConfirmButton> createState() => _ConfirmButtonState();
}

class _ConfirmButtonState extends State<_ConfirmButton> {
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
          width: 220,
          height: 50,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _hovered
                  ? [widget.accentLight, widget.accent]
                  : [widget.accent, const Color(0xFF00A87A)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: widget.accent.withValues(alpha: _hovered ? 0.45 : 0.20),
                blurRadius: _hovered ? 24 : 10,
                spreadRadius: _hovered ? 1 : 0,
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
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                color: Colors.black.withValues(alpha: 0.75),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
