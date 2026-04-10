import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'app_strings.dart'; // Re-exporta S, AppLocale, AppLocaleExt
import 'app_strings.dart';
import '../services/pref_keys.dart';

// ─── LocaleProvider ──────────────────────────────────────────────────────────
// StatefulWidget que envolve o app inteiro e expõe o locale atual.
// Auto-detecta o idioma do sistema no primeiro acesso.

class LocaleProvider extends StatefulWidget {
  final Widget child;
  const LocaleProvider({super.key, required this.child});

  /// Acessa o state do provider (para chamar setLocale).
  static LocaleProviderState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<LocaleProviderState>();

  @override
  State<LocaleProvider> createState() => LocaleProviderState();
}

class LocaleProviderState extends State<LocaleProvider> {
  AppLocale _locale = AppLocale.en;

  AppLocale get locale => _locale;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(PrefKey.locale.key);

    if (saved != null) {
      // Usuário já tem idioma salvo — usa ele
      if (mounted) setState(() => _locale = AppLocaleExt.fromCode(saved));
    } else {
      // Primeiro acesso: detecta do sistema e salva
      final detected = _detectSystemLocale();
      await prefs.setString(PrefKey.locale.key, detected.code);
      if (mounted) setState(() => _locale = detected);
    }
  }

  /// Detecta o idioma do sistema operacional.
  static AppLocale _detectSystemLocale() {
    try {
      final systemLocale = Platform.localeName; // ex: "pt_BR", "en_US"
      final lang = systemLocale.split(RegExp(r'[_\-]')).first.toLowerCase();
      return AppLocaleExt.fromSystemLang(lang);
    } catch (_) {
      return AppLocale.en;
    }
  }

  /// Persiste e aplica o novo locale.
  Future<void> setLocale(AppLocale locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefKey.locale.key, locale.code);
    if (mounted) setState(() => _locale = locale);
  }

  @override
  Widget build(BuildContext context) {
    return _LocaleScope(
      locale: _locale,
      child: widget.child,
    );
  }
}

// ─── _LocaleScope ─────────────────────────────────────────────────────────────
// InheritedWidget leve — reconstrói filhos quando o locale muda.

class _LocaleScope extends InheritedWidget {
  final AppLocale locale;
  const _LocaleScope({required this.locale, required super.child});

  static AppLocale of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LocaleScope>()?.locale ??
      AppLocale.ptBR;

  @override
  bool updateShouldNotify(_LocaleScope old) => old.locale != locale;
}

/// Atalho global: use `sOf(context)` em qualquer widget para obter strings traduzidas.
S sOf(BuildContext context) => S(_LocaleScope.of(context));
