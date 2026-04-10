import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/locale_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';
import 'services/logger_service.dart';
import 'services/play_time_service.dart';
import 'services/pref_keys.dart';

void main() async {
  // Captura erros síncronos do Flutter (widgets, rendering, etc.)
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Inicializa logging antes de tudo — erros de startup serão capturados
    await LoggerService.instance.init();
    await LoggerService.instance.info('Launcher iniciado');

    // Captura erros do framework Flutter (layout, build, paint)
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details); // Mostra no console debug
      LoggerService.instance.saveLauncherCrashReport(
        details.exception,
        details.stack,
      );
    };

    // Captura erros de plataforma não tratados (ex: plugin crashes)
    PlatformDispatcher.instance.onError = (error, stack) {
      LoggerService.instance.saveLauncherCrashReport(error, stack);
      return true; // Marca como handled — evita terminar o app
    };

    // Registra tempo de abertura do launcher
    await PlayTimeService().markLauncherOpened();

    // Configura janela apenas em desktop
    if (!Platform.isAndroid && !Platform.isIOS) {
      await windowManager.ensureInitialized();
      const WindowOptions windowOptions = WindowOptions(
        size: Size(1280, 720),
        title: 'CobbleHype',
        minimumSize: Size(1280, 720),
        center: true,
        backgroundColor: Color(0xFF0D0F14),
        titleBarStyle: TitleBarStyle.normal,
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.setResizable(false);
        await windowManager.show();
        await windowManager.focus();
      });
    }

    runApp(const LocaleProvider(child: CobbleHypeApp()));
  }, (error, stack) {
    // Captura erros assíncronos não tratados (Futures sem catch, etc.)
    LoggerService.instance.saveLauncherCrashReport(error, stack);
  });
}

class CobbleHypeApp extends StatelessWidget {
  const CobbleHypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CobbleHype Launcher',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const AppRouter(),
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00C896), // verde CobbleHype
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF0D0F14),
      fontFamily: 'Roboto',
    );
  }
}

/// Decide qual tela mostrar com base na sessão salva
class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  bool _loading = true;
  bool _isLoggedIn = false;
  bool _onboardingDone = false;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final prefs = await SharedPreferences.getInstance();
    final onboardingDone = prefs.getBool(PrefKey.onboardingDone.key) ?? false;
    bool isLoggedIn = false;

    try {
      isLoggedIn = await AuthService().loadSavedAccount() != null;
    } catch (_) {
      isLoggedIn = false;
    }

    if (!mounted) return;
    setState(() {
      _isLoggedIn = isLoggedIn;
      _onboardingDone = onboardingDone;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Primeiro acesso: mostra boas-vindas → login (idioma auto-detectado)
    if (!_onboardingDone) return const WelcomeScreen();

    return _isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}
