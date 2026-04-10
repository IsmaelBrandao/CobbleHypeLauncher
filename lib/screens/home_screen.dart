import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/locale_provider.dart';
import '../models/minecraft_account.dart';
import '../models/modpack.dart';
import '../services/android_launcher.dart';
import '../services/asset_manager.dart';
import '../services/auth_service.dart';
import '../services/java_manager.dart';
import '../services/launch_engine.dart';
import '../services/launcher_updater.dart';
import '../services/logger_service.dart';
import '../services/play_time_service.dart';
import '../services/pref_keys.dart';
import '../services/server_status_service.dart';
import '../services/update_engine.dart';
import 'login_screen.dart';
import 'settings_screen.dart';

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

// ─── LauncherState ────────────────────────────────────────────────────────────

enum LauncherState {
  idle,
  checkingUpdates,
  downloading,
  downloadingJava,
  downloadingAssets,
  launching,
  playing,
  error,
}

// ─── HomeScreen ───────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Links sociais — deixe vazio para esconder o botão
  static const String _discordUrl = 'https://discord.gg/cobblehype';
  static const String _storeUrl = ''; // URL da loja (vazio = esconde)

  static const Color _accent = Color(0xFF00C896);

  // Serviços
  final _auth = AuthService();
  final _javaManager = JavaManager();
  final _updateEngine = UpdateEngine();
  final _launchEngine = LaunchEngine();
  final _assetManager = AssetManager();
  final _playTime = PlayTimeService();
  final _serverStatus = ServerStatusService();
  final _updater = LauncherUpdater();
  final _androidLauncher = AndroidLauncher();

  // Strings traduzidas — atualizado em didChangeDependencies
  S _s = const S(AppLocale.ptBR);

  // Estado do launcher
  LauncherState _state = LauncherState.idle;
  String _statusText = '';
  double _progress = 0;
  MinecraftAccount? _account;

  // Cache do resultado de update check (evita re-checar no PLAY)
  bool _updateCheckDone = false;
  bool _hasModUpdate = false;

  // Estado do servidor
  ServerStatus _server = ServerStatus.offline;
  bool _checkingServer = false;
  DateTime? _lastServerCheck;

  // Tempo de jogo
  int _totalPlayMinutes = 0;

  // Console de log em tempo real
  final List<String> _logLines = [];
  bool _consoleVisible = false;
  final ScrollController _consoleScroll = ScrollController();
  Timer? _logFlushTimer;
  bool _pendingConsoleScroll = false;

  // Partículas
  late final AnimationController _particleCtrl;
  late final List<_Particle> _particles;
  final _rng = Random();

  // ---------------------------------------------------------------------------
  // Ciclo de vida
  // ---------------------------------------------------------------------------

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s = sOf(context);
    // Atualiza o status text se ainda for o padrão
    if (_state == LauncherState.idle && _statusText.isEmpty) {
      _statusText = _s.homeReady;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _particles = List.generate(15, (_) => _Particle.random(_rng));
    _loadAll();
  }

  @override
  void dispose() {
    _logFlushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _particleCtrl.dispose();
    _consoleScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pausa as partículas quando a janela é minimizada ou vai para background
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _particleCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      _particleCtrl.repeat();
    }
  }

  // ---------------------------------------------------------------------------
  // Lógica de negócio (preservada integralmente)
  // ---------------------------------------------------------------------------

  Future<void> _loadAll() async {
    await Future.wait([
      _loadAccount(),
      _loadPlayTime(),
      _checkServerStatus(),
      _checkUpdatesInBackground(),
      _checkLauncherUpdate(),
    ]);
  }

  Future<void> _loadAccount() async {
    final account = await _auth.refreshIfNeeded();
    if (mounted) setState(() => _account = account);
  }

  Future<void> _loadPlayTime() async {
    final minutes = await _playTime.getTotalMinutes();
    if (mounted) setState(() => _totalPlayMinutes = minutes);
  }

  Future<void> _checkServerStatus() async {
    if (kServerAddress.isEmpty) return;
    if (_checkingServer) return;

    final now = DateTime.now();
    if (_lastServerCheck != null &&
        now.difference(_lastServerCheck!) < const Duration(seconds: 30)) {
      return;
    }

    _lastServerCheck = now;
    setState(() => _checkingServer = true);
    try {
      final status = await _serverStatus.check(kServerAddress);
      if (!mounted) return;
      setState(() {
        _server = status;
        _checkingServer = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingServer = false);
    }
  }

  Future<void> _checkUpdatesInBackground() async {
    try {
      if (mounted) {
        setState(() {
          _state = LauncherState.checkingUpdates;
          _statusText = _s.homeChecking;
        });
      }
      final hasUpdate = await _updateEngine.hasUpdate();
      _updateCheckDone = true;
      _hasModUpdate = hasUpdate;
      if (mounted) {
        setState(() {
          _state = LauncherState.idle;
          _statusText = hasUpdate ? _s.homeUpdateAvailable : _s.homeReady;
        });
      }
    } catch (_) {
      _updateCheckDone = true;
      _hasModUpdate = false;
      if (mounted) {
        setState(() {
          _state = LauncherState.idle;
          _statusText = _s.homeReady;
        });
      }
    }
  }

  Future<void> _checkLauncherUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    final autoUpdate = prefs.getBool(PrefKey.autoUpdateLauncher.key) ?? true;
    if (!autoUpdate) return;

    final update = await _updater.checkForUpdate();
    if (update != null && mounted) {
      _showLauncherUpdateDialog(update);
    }
  }

  void _showLauncherUpdateDialog(LauncherUpdateInfo update) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E2B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: _accent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _s.homeLauncherUpdateTitle(update.version),
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _s.updateRecommend,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (update.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                update.releaseNotes,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ] else ...[
              const SizedBox(height: 10),
              Text(
                _s.homeLauncherUpdateBody,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_s.homeLater),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final uri = Uri.parse(update.downloadUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(_s.homeDownload),
          ),
        ],
      ),
    );
  }

  Future<void> _play() async {
    if (_account == null) return;

    final prefs = await SharedPreferences.getInstance();
    final ramMinMb = prefs.getInt(PrefKey.minRam.key) ?? 512;
    final ramMaxMb = prefs.getInt(PrefKey.maxRam.key) ?? 4096;
    final resolution = prefs.getString(PrefKey.resolution.key) ?? '1280x720';
    final fullscreen = prefs.getBool(PrefKey.fullscreen.key) ?? false;
    final jvmArgsExtra = prefs.getString(PrefKey.jvmArgsExtra.key);
    final javaOverride = prefs.getString(PrefKey.javaPathOverride.key);
    final closeLauncherOnLaunch = prefs.getBool(PrefKey.closeOnLaunch.key) ?? false;
    final javaInstalledFuture = _javaManager.isInstalled();
    final fabricInstalledFuture = _launchEngine.isFabricInstalled();
    final gameDirFuture = AssetManager.resolveGameDir();

    try {
      // 1. Verifica mods — pula se o check em background já confirmou "tudo ok"
      final needsSync = !_updateCheckDone || _hasModUpdate;

      if (needsSync) {
        setState(() {
          _state = LauncherState.checkingUpdates;
          _statusText = _s.homeVerifyingMods;
          _progress = 0;
        });

        final syncResult = await _updateEngine.syncMods(
          onProgress: (done, total, mod) {
            if (!mounted) return;
            setState(() {
              _state = LauncherState.downloading;
              _statusText = _s.homeDownloadingMods(done, total);
              _progress = total > 0 ? done / total : 0;
            });
          },
        );

        // Atualiza cache — próximo PLAY será instantâneo se nada mudar
        _updateCheckDone = true;
        _hasModUpdate = false;

        // Notifica o usuário quando está offline e usando mods em cache
        if (syncResult.versionNumber == 'offline' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.wifi_off_rounded, color: Colors.orangeAccent, size: 18),
                  const SizedBox(width: 8),
                  Text(_s.offlineModsSnackbar),
                ],
              ),
              backgroundColor: const Color(0xFF2A2520),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      // Android: delega ao PojavLauncher — pula Java, Fabric e launch engine
      if (Platform.isAndroid) {
        await _playAndroid();
        return;
      }

      // 2. Java
      if (!await javaInstalledFuture) {
        if (mounted) {
          setState(() {
            _state = LauncherState.downloadingJava;
            _statusText = _s.homeDownloadingJava;
            _progress = 0;
          });
        }
      }

      String javaPath = javaOverride ?? '';
      if (javaPath.isEmpty) {
        try {
          javaPath = await _javaManager.getJavaPath(
            onProgress: (status, progress) {
              if (!mounted) return;
              setState(() {
                _state = LauncherState.downloadingJava;
                _statusText = status;
                _progress = progress;
              });
            },
          );
        } catch (e) {
          await _playTime.endSession();
          if (mounted) {
            setState(() {
              _state = LauncherState.error;
              _statusText = _s.errorJavaTitle;
              _progress = 0;
            });
            _showErrorDialog(
              title: _s.errorJavaTitle,
              message: _s.errorJavaBody,
              detail: e.toString(),
              onRetry: _play,
            );
          }
          return;
        }
      }

      // 3. Fabric Loader (primeira vez)
      if (!await fabricInstalledFuture) {
        await _launchEngine.installFabric(
          onProgress: (status, progress) {
            if (!mounted) return;
            setState(() {
              _state = LauncherState.downloading;
              _statusText = status;
              _progress = progress;
            });
          },
        );
      }

      // 3.5 Assets do Minecraft (texturas, sons, etc.)
      final gameDir = await gameDirFuture;
      final assetsOk = await _assetManager.isComplete(gameDir);
      if (!assetsOk) {
        if (mounted) {
          setState(() {
            _state = LauncherState.downloadingAssets;
            _statusText = _s.homeDownloadingAssets;
            _progress = 0;
          });
        }
        try {
          await _assetManager.ensureAssets(
            gameDir: gameDir,
            onProgress: (done, total, asset) {
              if (!mounted) return;
              setState(() {
                _state = LauncherState.downloadingAssets;
                _statusText = _s.homeDownloadingAssetsProgress(done, total);
                _progress = total > 0 ? done / total : 0;
              });
            },
          );
        } catch (e) {
          // Falha de assets é não-fatal: o jogo pode abrir com assets parciais
          if (mounted) {
            setState(() {
              _statusText = '${_s.homeAssetsWarning}$e';
            });
          }
        }
      }

      // 4. Lança o jogo
      if (mounted) {
        setState(() {
          _state = LauncherState.launching;
          _statusText = _s.homeLaunchingGame;
          _progress = 1;
        });
      }

      _playTime.startSession();

      // Limpa log da sessão anterior ao iniciar nova partida
      if (mounted) setState(() => _logLines.clear());

      await _launchEngine.launch(
        javaPath: javaPath,
        account: _account!,
        ramMinMb: ramMinMb,
        ramMb: ramMaxMb,
        jvmArgsExtra: jvmArgsExtra,
        resolution: resolution,
        fullscreen: fullscreen,
        // Assets já foram garantidos acima — evita download duplo dentro do engine
        ensureAssets: false,
        onLog: (line) {
          if (!mounted) return;
          _logLines.add(line);
          if (_logLines.length > 500) _logLines.removeAt(0);
          // Debounce: rebuild no máximo a cada 100ms (evita 100+ rebuilds/s)
          _logFlushTimer ??= Timer(const Duration(milliseconds: 100), () {
            _logFlushTimer = null;
            if (!mounted) return;
            setState(() {});
            if (!_pendingConsoleScroll) {
              _pendingConsoleScroll = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _pendingConsoleScroll = false;
                if (_consoleScroll.hasClients) {
                  _consoleScroll.jumpTo(
                    _consoleScroll.position.maxScrollExtent,
                  );
                }
              });
            }
          });
        },
        onGameStarted: () {
          if (mounted) {
            setState(() {
              _state = LauncherState.playing;
              _statusText = _s.homePlayingLabel;
            });
          }
          if (closeLauncherOnLaunch) exit(0);
        },
        onGameExit: () async {
          await _playTime.endSession();
          final minutes = await _playTime.getTotalMinutes();
          if (mounted) {
            setState(() {
              _totalPlayMinutes = minutes;
              _state = LauncherState.idle;
              _statusText = _s.homeReady;
              _progress = 0;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _state = LauncherState.idle;
          _statusText = _s.homeReady;
          _progress = 0;
        });
      }
    } on GameCrashException catch (e) {
      await _playTime.endSession();
      // Salva crash report do jogo em arquivo
      final crashPath = await LoggerService.instance.saveGameCrashReport(
        e.crash.exitCode,
        e.crash.lastLog,
      );
      if (mounted) {
        setState(() {
          _state = LauncherState.error;
          _statusText = '${_s.crashTitle} (${_s.crashExitCode}: ${e.crash.exitCode}).';
          _progress = 0;
        });
        _showCrashDialog(e.crash, crashReportPath: crashPath);
      }
    } catch (e) {
      await _playTime.endSession();
      if (mounted) {
        setState(() {
          _state = LauncherState.error;
          _statusText = '${_s.homeErrorPrefix}$e';
          _progress = 0;
        });
        _showErrorDialog(
          title: _s.errorLaunchTitle,
          message: _s.errorLaunchBody,
          detail: e.toString(),
          onRetry: _play,
        );
      }
    }
  }

  /// Fluxo de lançamento exclusivo para Android via PojavLauncher.
  Future<void> _playAndroid() async {
    if (_account == null) return;

    // 1. Verifica se o PojavLauncher está instalado
    setState(() {
      _state = LauncherState.launching;
      _statusText = _s.homeVerifyingPojav;
    });

    final installed = await _androidLauncher.isPojavInstalled();

    if (!installed) {
      if (mounted) {
        setState(() {
          _state = LauncherState.idle;
          _statusText = _s.homeReady;
        });
        _showPojavInstallDialog();
      }
      return;
    }

    // 2. Pré-configura a conta no PojavLauncher
    if (mounted) setState(() => _statusText = _s.homeConfigAccount);
    await _androidLauncher.preConfigureAccount(_account!);

    // 3. Sincroniza mods para a pasta do PojavLauncher
    if (mounted) setState(() => _statusText = _s.homeSyncingMods);
    final gameDir = await AssetManager.resolveGameDir();
    await _androidLauncher.syncMods('$gameDir/mods');

    // 4. Lança o PojavLauncher
    if (mounted) setState(() => _statusText = _s.homeOpeningPojav);
    await _androidLauncher.launch();

    if (mounted) {
      setState(() {
        _state = LauncherState.idle;
        _statusText = _s.homeReady;
        _progress = 0;
      });
    }
  }

  void _showPojavInstallDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(_s.homePojavTitle),
        content: Text(_s.homePojavBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(_s.homePojavCancel),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _androidLauncher.promptInstallPojav();
            },
            child: Text(_s.homePojavDownload),
          ),
        ],
      ),
    );
  }

  /// Exibe o dialog de crash com as últimas linhas de log e botões de ação.
  void _showCrashDialog(GameCrashInfo crash, {String? crashReportPath}) {
    // Determina pasta de logs: diretório do crashReportPath ou pasta padrão de logs
    String? logsFolderPath;
    if (crashReportPath != null) {
      final file = File(crashReportPath);
      logsFolderPath = file.parent.path;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E2B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _s.crashTitle,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_s.crashExitCode}: ${crash.exitCode}',
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70),
              ),
              if (crashReportPath != null) ...[
                const SizedBox(height: 6),
                SelectableText(
                  '${_s.crashReportSaved}:\n$crashReportPath',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white38,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      crash.lastLog.isEmpty
                          ? _s.crashNoOutput
                          : crash.lastLog,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          // Botão: Abrir pasta de logs
          if (logsFolderPath != null)
            TextButton.icon(
              onPressed: () async {
                final uri = Uri.file(logsFolderPath!);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                }
              },
              icon: const Icon(Icons.folder_open_rounded, size: 16),
              label: Text(_s.crashOpenFolder),
            ),
          // Botão: Copiar log
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                text: '${_s.crashExitCode}: ${crash.exitCode}\n\n${crash.lastLog}',
              ));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(_s.crashLogCopied),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(_s.crashCopyLog),
          ),
          // Botão primário: Tentar novamente
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _state = LauncherState.idle;
                _statusText = _s.homeReady;
                _progress = 0;
              });
              _play();
            },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_s.retryAction),
          ),
        ],
      ),
    );
  }

  /// Dialog de erro reutilizável com detalhes técnicos opcionais e botão de retry.
  void _showErrorDialog({
    required String title,
    required String message,
    String? detail,
    VoidCallback? onRetry,
  }) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E2B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 24),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            if (detail != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  detail,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _state = LauncherState.idle;
                _statusText = _s.homeReady;
                _progress = 0;
              });
            },
            child: Text(_s.closeAction),
          ),
          if (onRetry != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                onRetry();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(_s.retryAction),
            ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  bool get _canPlay =>
      _state == LauncherState.idle || _state == LauncherState.error;

  // ---------------------------------------------------------------------------
  // Build — Helios layout
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

          // 2. Gradiente escuro: mais leve no topo, mais denso na base
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.75),
                ],
              ),
            ),
          ),

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

          // 4. Logo (topo-esquerdo)
          _buildLogoTopLeft(),

          // 5. Perfil do jogador + botões de ação (topo-direito)
          _buildPlayerPanel(),

          // 6. Barra inferior estilo Helios
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomBar(),
          ),

          // 7. Painel de console (visível acima da barra inferior quando ativado)
          if (_consoleVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90, // altura da bottom bar
              child: _buildConsolePanel(),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Logo (topo-esquerdo)
  // ---------------------------------------------------------------------------

  Widget _buildLogoTopLeft() {
    return Positioned(
      top: 16,
      left: 16,
      child: Image.asset(
        'assets/images/logo2.png',
        width: 110,
        height: 110,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.grass_rounded,
          color: Colors.white54,
          size: 48,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Painel do jogador (topo-direito)
  // ---------------------------------------------------------------------------

  Widget _buildPlayerPanel() {
    // mc-heads.net aceita UUID e username — funciona pra Microsoft e Offline
    final identifier =
        _account?.uuid.isNotEmpty == true && _account?.isOffline == false
            ? _account!.uuid
            : _account?.username;
    final skinUrl = identifier != null
        ? 'https://mc-heads.net/head/$identifier/128'
        : null;

    return Positioned(
      top: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.07),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Perfil clicável: Skin + Nick → abre Configurações > Conta
            _ProfileChip(
              skinUrl: skinUrl,
              username: _account?.username,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(initialSection: 0),
                ),
              ).then((_) => _loadAccount()),
            ),

            const SizedBox(width: 6),

            // Separador vertical
            Container(
              width: 1,
              height: 24,
              color: Colors.white.withValues(alpha: 0.10),
            ),

            const SizedBox(width: 4),

            // Botões de ação (horizontal)
            _buildPanelButton(
              icon: Icons.settings_outlined,
              tooltip: _s.homeSettings,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(initialSection: 1),
                ),
              ).then((_) => _loadAccount()),
            ),

            if (_discordUrl.isNotEmpty)
              _buildPanelButton(
                faIcon: FontAwesomeIcons.discord,
                tooltip: _s.homeDiscord,
                onTap: () async {
                  final uri = Uri.parse(_discordUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),

            if (_storeUrl.isNotEmpty)
              _buildPanelButton(
                icon: Icons.storefront_outlined,
                tooltip: _s.homeStore,
                onTap: () async {
                  final uri = Uri.parse(_storeUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),

            _buildPanelButton(
              icon: Icons.logout_rounded,
              tooltip: _s.homeLogout,
              onTap: _logout,
              isDestructive: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanelButton({
    IconData? icon,
    IconData? faIcon,
    required String tooltip,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return _PanelIconButton(
      icon: icon,
      faIcon: faIcon,
      tooltip: tooltip,
      onTap: onTap,
      isDestructive: isDestructive,
    );
  }

  // ---------------------------------------------------------------------------
  // Barra inferior — estilo Helios
  // ---------------------------------------------------------------------------

  Widget _buildBottomBar() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: 90,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Esquerda: Players
              _buildPlayersSection(),

              const Spacer(),

              // Centro: PLAY
              _buildPlaySection(),

              const Spacer(),

              // Direita: Info do servidor
              _buildServerInfoSection(),
            ],
          ),
        ),
      ),
    );
  }

  // Seção de jogadores online (esquerda)
  Widget _buildPlayersSection() {
    return GestureDetector(
      onTap: _checkServerStatus,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sOf(context).homePlayers,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 2),
          if (_checkingServer)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.white54,
              ),
            )
          else if (!_server.online)
            const Text(
              '---',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Text(
              '${_server.playersOnline}/${_server.playersMax}',
              style: const TextStyle(
                color: Color(0xE5FFFFFF), // white90
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  // Seção de play central
  Widget _buildPlaySection() {
    final bool showProgress = _state != LauncherState.idle &&
        _state != LauncherState.error &&
        _state != LauncherState.playing;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Botão principal centralizado, com console toggle posicionado ao lado
        // sem afetar o alinhamento central do botão PLAY
        Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            _buildPlayButton(),
            // Botão de console posicionado à direita do botão PLAY
            if (_state == LauncherState.playing || _logLines.isNotEmpty)
              Positioned(
                right: -38,
                child: Tooltip(
                  message: _consoleVisible
                      ? sOf(context).closeAction
                      : 'Console',
                  child: IconButton(
                    icon: Icon(
                      Icons.terminal_rounded,
                      color: _consoleVisible
                          ? _accent
                          : Colors.white.withValues(alpha: 0.45),
                      size: 18,
                    ),
                    onPressed: () =>
                        setState(() => _consoleVisible = !_consoleVisible),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                  ),
                ),
              ),
          ],
        ),

        // Status text (com botão retry no estado de erro)
        const SizedBox(height: 2),
        if (_state == LauncherState.error)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _statusText,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: _s.retryAction,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _state = LauncherState.idle;
                      _statusText = _s.homeReady;
                      _progress = 0;
                    });
                    _play();
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.refresh_rounded,
                      color: Colors.redAccent,
                      size: 14,
                    ),
                  ),
                ),
              ),
            ],
          )
        else
          Text(
            _statusText,
            style: const TextStyle(
              color: Color(0x80FFFFFF), // white50
              fontSize: 11,
            ),
          ),

        // Barra de progresso (visível durante downloads/launches)
        if (showProgress) ...[
          const SizedBox(height: 4),
          SizedBox(
            width: 200,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 3,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ),
        ],

        // Tempo jogado (abaixo da barra de progresso quando visível)
        if (_totalPlayMinutes > 0 && !showProgress) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timer_outlined,
                size: 11,
                color: Colors.white.withValues(alpha: 0.30),
              ),
              const SizedBox(width: 3),
              Text(
                '${PlayTimeService.format(_totalPlayMinutes)} ${_s.homePlayedSuffix}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.30),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Painel de console em tempo real
  // ---------------------------------------------------------------------------

  Widget _buildConsolePanel() {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
      ),
      child: Column(
        children: [
          // Cabeçalho compacto
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: Colors.white.withValues(alpha: 0.04),
            child: Row(
              children: [
                Icon(
                  Icons.terminal_rounded,
                  size: 13,
                  color: _accent.withValues(alpha: 0.80),
                ),
                const SizedBox(width: 6),
                Text(
                  'Console',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                // Botão fechar console
                GestureDetector(
                  onTap: () => setState(() => _consoleVisible = false),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.40),
                  ),
                ),
              ],
            ),
          ),

          // Área de log
          Expanded(
            child: _logLines.isEmpty
                ? Center(
                    child: Text(
                      'Aguardando início do jogo...',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.25),
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _consoleScroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    itemCount: _logLines.length,
                    itemBuilder: (_, i) => Text(
                      _logLines[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    switch (_state) {
      case LauncherState.launching:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _accent.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                sOf(context).homeLaunching,
                style: TextStyle(
                  color: _accent.withValues(alpha: 0.7),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        );

      case LauncherState.playing:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _accent.withValues(alpha: 0.5)),
          ),
          child: Text(
            sOf(context).homePlaying,
            style: const TextStyle(
              color: _accent,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
        );

      default:
        if (_canPlay) {
          return _PlayButton(onTap: _play);
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Text(
            sOf(context).homeWait,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
        );
    }
  }

  // Seção de info do servidor (direita)
  Widget _buildServerInfoSection() {
    final bool online = _server.online;
    final statusColor =
        online ? const Color(0xFF4CAF50) : Colors.redAccent;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Indicador de status
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: 0.55),
                    blurRadius: 5,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            const Text(
              'CobbleHype',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        if (kServerAddress.isNotEmpty)
          const Text(
            kServerAddress,
            style: TextStyle(
              color: Color(0x66FFFFFF), // white40
              fontSize: 11,
            ),
          ),
      ],
    );
  }
}

// ─── _PlayButton ──────────────────────────────────────────────────────────────
// Botão PLAY grande e chamativo — verde, impossível de ignorar.

class _PlayButton extends StatefulWidget {
  final VoidCallback onTap;

  const _PlayButton({required this.onTap});

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  static const Color _green = Color(0xFF00C896);
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
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _hovered
                  ? [const Color(0xFF00E6A8), _green]
                  : [_green, const Color(0xFF00A87A)],
            ),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: _green.withValues(alpha: _hovered ? 0.50 : 0.25),
                blurRadius: _hovered ? 24 : 12,
                spreadRadius: _hovered ? 2 : 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_arrow_rounded,
                color: Colors.black.withValues(alpha: 0.85),
                size: 22,
              ),
              const SizedBox(width: 6),
              Text(
                sOf(context).homePlay,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.85),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── _SkinHead3D ─────────────────────────────────────────────────────────────
// Cabeça 3D da skin com animação de mouse-tracking (estilo SK Launcher).
// Quando o mouse se move, a cabeça gira suavemente acompanhando o cursor.

class _SkinHead3D extends StatefulWidget {
  final String? skinUrl;
  final double size;

  const _SkinHead3D({required this.skinUrl, this.size = 80});

  @override
  State<_SkinHead3D> createState() => _SkinHead3DState();
}

class _SkinHead3DState extends State<_SkinHead3D> {
  // Ângulo atual de rotação (normalizado de -1 a 1)
  double _rotX = 0; // vertical (pitch)
  double _rotY = 0; // horizontal (yaw)

  // Limites de rotação em radianos (~15°)
  static const double _maxAngle = 0.26;

  void _onHover(PointerEvent event) {
    // Calcula offset relativo ao centro do widget
    final center = Offset(widget.size / 2, widget.size / 2);
    final dx = (event.localPosition.dx - center.dx) / center.dx; // -1 a 1
    final dy = (event.localPosition.dy - center.dy) / center.dy; // -1 a 1

    setState(() {
      _rotY = dx.clamp(-1.0, 1.0);
      _rotX = -dy.clamp(-1.0, 1.0); // Invertido: mouse pra cima = cabeça olha pra cima
    });
  }

  void _onExit(PointerEvent _) {
    // Volta à posição neutra suavemente (o TweenAnimationBuilder cuida da transição)
    setState(() {
      _rotX = 0;
      _rotY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: _onHover,
      onExit: _onExit,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: _rotX),
        duration: const Duration(milliseconds: 120),
        builder: (_, animRotX, child) {
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _rotY),
            duration: const Duration(milliseconds: 120),
            builder: (_, animRotY, child) {
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001) // perspectiva sutil
                  ..rotateX(animRotX * _maxAngle)
                  ..rotateY(animRotY * _maxAngle),
                child: child,
              );
            },
            child: child,
          );
        },
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: widget.skinUrl != null
              ? Image.network(
                  widget.skinUrl!,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => _fallbackHead(),
                )
              : _fallbackHead(),
        ),
      ),
    );
  }

  Widget _fallbackHead() {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      child: Icon(
        Icons.person_rounded,
        color: Colors.white38,
        size: widget.size * 0.55,
      ),
    );
  }
}

// ─── _PanelIconButton ────────────────────────────────────────────────────────
// Botão compacto do painel de perfil — hover com fundo + accent sutil

class _PanelIconButton extends StatefulWidget {
  final IconData? icon;
  final IconData? faIcon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isDestructive;

  const _PanelIconButton({
    this.icon,
    this.faIcon,
    required this.tooltip,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  State<_PanelIconButton> createState() => _PanelIconButtonState();
}

class _PanelIconButtonState extends State<_PanelIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.isDestructive
        ? Colors.redAccent.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.10);
    final iconColor = widget.isDestructive
        ? (_hovered ? Colors.redAccent : Colors.white54)
        : (_hovered ? Colors.white : Colors.white54);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _hovered ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: widget.faIcon != null
                  ? FaIcon(widget.faIcon!, color: iconColor, size: 15)
                  : Icon(widget.icon, color: iconColor, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── _ProfileChip ────────────────────────────────────────────────────────────
// Chip clicável: Skin + Nick + label "Perfil" — abre configurações da conta

class _ProfileChip extends StatefulWidget {
  final String? skinUrl;
  final String? username;
  final VoidCallback onTap;

  const _ProfileChip({
    required this.skinUrl,
    required this.username,
    required this.onTap,
  });

  @override
  State<_ProfileChip> createState() => _ProfileChipState();
}

class _ProfileChipState extends State<_ProfileChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: sOf(context).homeProfileTooltip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Skin 3D pequena
                _SkinHead3D(skinUrl: widget.skinUrl, size: 32),

                const SizedBox(width: 8),

                // Nick + label "Perfil"
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.username != null)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: Text(
                          widget.username!,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ),
                    const SizedBox(height: 1),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          sOf(context).homeProfile,
                          style: TextStyle(
                            color: _hovered
                                ? const Color(0xFF00C896)
                                : Colors.white.withValues(alpha: 0.40),
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 12,
                          color: _hovered
                              ? const Color(0xFF00C896)
                              : Colors.white.withValues(alpha: 0.30),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
