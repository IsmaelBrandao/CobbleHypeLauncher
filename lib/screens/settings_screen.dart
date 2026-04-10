import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/locale_provider.dart';
import '../models/minecraft_account.dart';
import '../models/modpack.dart';
import '../services/auth_service.dart';
import '../services/launcher_updater.dart';
import '../services/play_time_service.dart';
import '../services/pref_keys.dart';
import 'login_screen.dart';

// ─── Cores do tema ────────────────────────────────────────────────────────────
const _kAccent   = Color(0xFF00C896);
const _kDivider  = Color(0x14FFFFFF); // white 8%
const _kSidebarBg  = Color(0xCC0D1620); // 80% opaque

class SettingsScreen extends StatefulWidget {
  /// Seção inicial: 0=Conta, 1=Jogo, 2=Launcher, 3=Pastas, 4=Sobre
  final int initialSection;
  const SettingsScreen({super.key, this.initialSection = 0});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _auth    = AuthService();
  final _updater = LauncherUpdater();
  final _playTime = PlayTimeService();

  late int _selectedSection = widget.initialSection;
  bool _loading = true;

  // Traduções
  S _s = const S(AppLocale.ptBR);

  // Conta
  MinecraftAccount? _account;
  PlayStats _stats = const PlayStats(
    totalPlayMinutes: 0,
    sessionCount: 0,
    firstPlayed: null,
    launcherMinutes: 0,
  );

  // Jogo
  double _ramMinMb = 512;
  double _ramMaxMb = 4096;
  int _systemRamMB = 8192; // detectado em _loadAll()
  bool _ramOverWarning = false;
  String _resolution = '1280x720';
  bool _fullscreen = false;
  final _jvmArgsController  = TextEditingController();
  final _javaPathController  = TextEditingController();
  final _resWidthController  = TextEditingController();
  final _resHeightController = TextEditingController();

  // Launcher
  bool _closeLauncherOnLaunch = false;
  bool _autoUpdateLauncher    = true;

  // Sobre
  String _appVersion    = '...';
  bool   _checkingUpdate = false;
  String _updateStatus  = '';

  static const List<String> _presetResolutions = [
    '854x480', '1280x720', '1920x1080', '2560x1440',
  ];
  bool get _isCustomResolution => !_presetResolutions.contains(_resolution);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s = sOf(context);
  }

  @override
  void dispose() {
    _jvmArgsController.dispose();
    _javaPathController.dispose();
    _resWidthController.dispose();
    _resHeightController.dispose();
    super.dispose();
  }

  // ── Lógica ──────────────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    final prefs     = await SharedPreferences.getInstance();
    final info      = await PackageInfo.fromPlatform();
    final account   = await _auth.loadSavedAccount();
    final stats     = await _playTime.getStats();
    final systemRam = await _getSystemRamMB();

    final savedRamMax = (prefs.getInt(PrefKey.maxRam.key) ?? 4096).toDouble();

    setState(() {
      _account              = account;
      _stats                = stats;
      _systemRamMB          = systemRam;
      _ramMinMb             = (prefs.getInt(PrefKey.minRam.key) ?? 512).toDouble();
      _ramMaxMb             = savedRamMax;
      _ramOverWarning       = savedRamMax > systemRam * 0.75;
      _resolution           = prefs.getString(PrefKey.resolution.key) ?? '1280x720';
      _fullscreen           = prefs.getBool(PrefKey.fullscreen.key) ?? false;
      _jvmArgsController.text  = prefs.getString(PrefKey.jvmArgsExtra.key) ?? '';
      _javaPathController.text = prefs.getString(PrefKey.javaPathOverride.key) ?? '';
      _closeLauncherOnLaunch   = prefs.getBool(PrefKey.closeOnLaunch.key) ?? false;
      _autoUpdateLauncher      = prefs.getBool(PrefKey.autoUpdateLauncher.key) ?? true;
      _appVersion              = info.version;
      _loading                 = false;

      if (_isCustomResolution) {
        final parts = _resolution.split('x');
        _resWidthController.text  = parts.isNotEmpty  ? parts[0] : '1280';
        _resHeightController.text = parts.length > 1 ? parts[1] : '720';
      }
    });
  }

  /// Detecta a RAM total do sistema em MB.
  /// Retorna 8192 (8GB) como fallback caso a detecção falhe.
  Future<int> _getSystemRamMB() async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run(
            'wmic', ['ComputerSystem', 'get', 'TotalPhysicalMemory', '/value']);
        final match = RegExp(r'TotalPhysicalMemory=(\d+)')
            .firstMatch(result.stdout as String);
        if (match != null) {
          return int.parse(match.group(1)!) ~/ (1024 * 1024);
        }
      } else if (Platform.isLinux) {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
        if (match != null) return int.parse(match.group(1)!) ~/ 1024;
      } else if (Platform.isMacOS) {
        final result = await Process.run('sysctl', ['-n', 'hw.memsize']);
        final raw = (result.stdout as String).trim();
        if (raw.isNotEmpty) return int.parse(raw) ~/ (1024 * 1024);
      }
    } catch (_) {}
    return 8192; // fallback 8GB
  }

  /// Rejeita argumentos JVM que podem comprometer a JVM ou o launcher
  bool _isJvmArgsSafe(String args) {
    final dangerous = RegExp(
      r'-javaagent:|'
      r'-Xbootclasspath:|'
      r'-agentlib:|'
      r'-agentpath:|'
      r'-Djava\.security',
      caseSensitive: false,
    );
    return !dangerous.hasMatch(args);
  }

  Future<void> _save() async {
    // Valida JVM args antes de salvar
    if (!_isJvmArgsSafe(_jvmArgsController.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.shield_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_s.jvmArgsBlocked)),
            ],
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(PrefKey.minRam.key, _ramMinMb.toInt());
    await prefs.setInt(PrefKey.maxRam.key, _ramMaxMb.toInt());
    await prefs.setString(PrefKey.resolution.key, _resolution);
    await prefs.setBool(PrefKey.fullscreen.key, _fullscreen);
    await prefs.setString(PrefKey.jvmArgsExtra.key, _jvmArgsController.text.trim());
    final javaPath = _javaPathController.text.trim();
    if (javaPath.isEmpty) {
      await prefs.remove(PrefKey.javaPathOverride.key);
    } else {
      await prefs.setString(PrefKey.javaPathOverride.key, javaPath);
    }
    await prefs.setBool(PrefKey.closeOnLaunch.key, _closeLauncherOnLaunch);
    await prefs.setBool(PrefKey.autoUpdateLauncher.key, _autoUpdateLauncher);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_s.settingsSaved),
        backgroundColor: _kAccent.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141E2A),
        title: Text(_s.accountLogoutConfirmTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(_s.accountLogoutConfirmBody,
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_s.accountCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text(_s.accountLogout),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _openFolder(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    final uri = Uri.file(path);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<String> _getGameDir() async {
    final prefs  = await SharedPreferences.getInstance();
    final custom = prefs.getString(PrefKey.gameDirectory.key);
    if (custom != null) return custom;
    final base = await getApplicationSupportDirectory();
    return '${base.path}/minecraft';
  }

  Future<void> _checkForUpdates() async {
    setState(() { _checkingUpdate = true; _updateStatus = _s.aboutChecking; });
    try {
      final update = await _updater.checkForUpdate();
      if (!mounted) return;
      if (update != null) {
        setState(() => _updateStatus =
            '${_s.aboutUpdateAvailable}: v${update.version}');
        _showUpdateDialog(update);
      } else {
        setState(() => _updateStatus = _s.aboutUpToDate);
      }
    } catch (e) {
      if (mounted) setState(() => _updateStatus = _s.aboutCheckError);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showUpdateDialog(LauncherUpdateInfo update) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141E2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: _kAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _s.homeLauncherUpdateTitle(update.version),
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
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
            style: FilledButton.styleFrom(backgroundColor: _kAccent),
            icon: const Icon(Icons.download_rounded, size: 18, color: Colors.black),
            label: Text(_s.homeDownload,
                style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: _kAccent,
          surface: Color(0xFF141E2A),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: _kAccent,
          thumbColor: _kAccent,
          inactiveTrackColor: Colors.white12,
          overlayColor: _kAccent.withValues(alpha: 0.12),
          trackHeight: 3,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? _kAccent : null),
          trackColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected)
                  ? _kAccent.withValues(alpha: 0.35)
                  : null),
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Background image
            Image.asset(
              'assets/images/backgroundsettings.png',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Container(color: const Color(0xFF071410)),
            ),
            // Gradiente escuro
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xE0080E14),
                    Color(0x99080E14),
                    Color(0x66080E14),
                  ],
                  stops: [0.0, 0.35, 1.0],
                ),
              ),
            ),
            // Conteúdo
            if (_loading)
              const Center(child: CircularProgressIndicator(color: _kAccent))
            else
              Row(
                children: [
                  _buildSidebar(),
                  Expanded(child: _buildContent()),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ── Sidebar ─────────────────────────────────────────────────────────────────

  Widget _buildSidebar() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          width: 210,
          decoration: BoxDecoration(
            color: _kSidebarBg,
            border: Border(
              right: BorderSide(
                color: Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
                child: Row(
                  children: [
                    _SidebarIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: _s.settingsBack,
                      onTap: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [Colors.white, Color(0xFFB0FFE0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ).createShader(bounds),
                  child: Text(
                    _s.settingsTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
              _navItem(0, Icons.person_outline_rounded, _s.settingsNavAccount),
              _navItem(1, Icons.sports_esports_outlined, _s.settingsNavGame),
              _navItem(2, Icons.tune_outlined, _s.settingsNavLauncher),
              _navItem(3, Icons.folder_outlined, _s.settingsNavFolders),
              _navItem(4, Icons.info_outline_rounded, _s.settingsNavAbout),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                child: _SaveButton(label: _s.settingsSave, onTap: _save),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final sel = _selectedSection == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => setState(() => _selectedSection = index),
          borderRadius: BorderRadius.circular(8),
          hoverColor: Colors.white.withValues(alpha: 0.05),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: sel
                ? BoxDecoration(
                    color: _kAccent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: const Border(
                      left: BorderSide(color: _kAccent, width: 2.5),
                    ),
                  )
                : const BoxDecoration(),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: sel ? _kAccent : Colors.white54),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: sel ? Colors.white : Colors.white54,
                    fontSize: 14,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Conteúdo ────────────────────────────────────────────────────────────────

  Widget _buildContent() {
    return IndexedStack(
      index: _selectedSection,
      children: [
        _buildAccountSection(),
        _buildGameSection(),
        _buildLauncherSection(),
        _buildFoldersSection(),
        _buildAboutSection(),
      ],
    );
  }

  Widget _glassSection({required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xB30A0F16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.07),
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(36, 32, 36, 36),
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  // ── Seção Conta (REDESENHADA) ───────────────────────────────────────────────

  Widget _buildAccountSection() {
    return _glassSection(
      children: [
        _contentHeader(_s.accountTitle, _s.accountSubtitle),
        _divider(),

        if (_account != null) ...[
          // Layout principal: Skin + Info lado a lado
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Skin body 3D com rotação
              _SkinBody3D(
                skinUrl: _account!.skinBodyUrl,
                size: 220,
              ),

              const SizedBox(width: 32),

              // Info + Stats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Username grande
                    Text(
                      _account!.username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Badge tipo de conta
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _account!.isOffline
                            ? Colors.orange.withValues(alpha: 0.12)
                            : _kAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _account!.isOffline
                              ? Colors.orange.withValues(alpha: 0.30)
                              : _kAccent.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _account!.isOffline
                                ? Icons.wifi_off_rounded
                                : Icons.verified_rounded,
                            size: 13,
                            color: _account!.isOffline
                                ? Colors.orange
                                : _kAccent,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _account!.isOffline
                                ? _s.accountOffline
                                : _s.accountMicrosoft,
                            style: TextStyle(
                              color: _account!.isOffline
                                  ? Colors.orange
                                  : _kAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (!_account!.isOffline) ...[
                      const SizedBox(height: 6),
                      Text(
                        'UUID: ${_account!.uuid.substring(0, 8)}...',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Stats grid
                    _buildStatsGrid(),

                    const SizedBox(height: 24),

                    // Botão sair
                    _DestructiveButton(
                      label: _s.accountLogout,
                      icon: Icons.logout_rounded,
                      onTap: _logout,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ] else
          Text(
            _s.accountNoAccount,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.40), fontSize: 14),
          ),
      ],
    );
  }

  Widget _buildStatsGrid() {
    final firstPlayedStr = _stats.firstPlayed != null
        ? '${_stats.firstPlayed!.day.toString().padLeft(2, '0')}/'
          '${_stats.firstPlayed!.month.toString().padLeft(2, '0')}/'
          '${_stats.firstPlayed!.year}'
        : _s.statsNever;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _StatCard(
          icon: Icons.timer_outlined,
          label: _s.statsPlayTime,
          value: PlayTimeService.format(_stats.totalPlayMinutes),
        ),
        _StatCard(
          icon: Icons.sports_esports_outlined,
          label: _s.statsSessions,
          value: '${_stats.sessionCount}',
        ),
        _StatCard(
          icon: Icons.desktop_windows_outlined,
          label: _s.statsLauncherTime,
          value: PlayTimeService.format(_stats.launcherMinutes),
        ),
        _StatCard(
          icon: Icons.calendar_today_outlined,
          label: _s.statsFirstPlayed,
          value: firstPlayedStr,
        ),
      ],
    );
  }

  // ── Seção Jogo ───────────────────────────────────────────────────────────────

  Widget _buildGameSection() {
    return _glassSection(
      children: [
        _contentHeader(_s.gameTitle, _s.gameSubtitle),
        _divider(),

        _subSectionTitle(_s.gameMemory, Icons.memory_rounded),
        const SizedBox(height: 12),
        _ramSlider(
          label: _s.gameRamMin,
          value: _ramMinMb,
          min: 512,
          max: (_ramMaxMb - 512).clamp(512, _systemRamMB.toDouble() - 512),
          onChanged: (v) => setState(() => _ramMinMb = v),
        ),
        const SizedBox(height: 8),
        _ramSlider(
          label: _s.gameRamMax,
          value: _ramMaxMb,
          min: (_ramMinMb + 512).clamp(1024, _systemRamMB.toDouble()),
          max: _systemRamMB.toDouble(),
          onChanged: (v) {
            setState(() {
              _ramMaxMb = v;
              _ramOverWarning = v > _systemRamMB * 0.75;
            });
          },
        ),
        const SizedBox(height: 10),
        // Texto informativo sobre RAM do sistema e recomendação
        Text(
          'Sistema: ${(_systemRamMB / 1024).toStringAsFixed(0)} GB'
          ' — Recomendado: ${(_systemRamMB / 2 / 1024).toStringAsFixed(0)} GB para Minecraft',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38), fontSize: 12),
        ),
        // Aviso quando o usuário aloca mais de 75% da RAM
        if (_ramOverWarning) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.30)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Atenção: alocar mais de 75% da RAM pode causar instabilidade.',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        _divider(),

        _subSectionTitle(_s.gameResolution, Icons.monitor_rounded),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._presetResolutions.map((r) => _ResChip(
                  label: r,
                  selected: _resolution == r,
                  onTap: () => setState(() => _resolution = r),
                )),
            _ResChip(
              label: _s.gameCustom,
              selected: _isCustomResolution,
              onTap: () => setState(() {
                _resWidthController.text  = '1280';
                _resHeightController.text = '720';
                _resolution = '1280x720';
              }),
            ),
          ],
        ),
        if (_isCustomResolution) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              _darkField(
                controller: _resWidthController,
                hint: 'Largura',
                suffix: 'px',
                width: 110,
                onChanged: (v) {
                  final h = _resHeightController.text;
                  if (v.isNotEmpty && h.isNotEmpty) {
                    setState(() => _resolution = '${v}x$h');
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('×',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 18)),
              ),
              _darkField(
                controller: _resHeightController,
                hint: 'Altura',
                suffix: 'px',
                width: 110,
                onChanged: (v) {
                  final w = _resWidthController.text;
                  if (v.isNotEmpty && w.isNotEmpty) {
                    setState(() => _resolution = '${w}x$v');
                  }
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _heliosSwitch(
          title: _s.gameFullscreen,
          subtitle: _s.gameFullscreenSub,
          value: _fullscreen,
          onChanged: (v) => setState(() => _fullscreen = v),
        ),
        _divider(),

        _subSectionTitle(_s.gameJava, Icons.coffee_rounded),
        const SizedBox(height: 6),
        Text(
          _s.gameJavaHint,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.40), fontSize: 12),
        ),
        const SizedBox(height: 10),
        _javaPathField(),
        _divider(),

        _subSectionTitle(_s.gameJvmArgs, Icons.code_rounded),
        const SizedBox(height: 10),
        _darkTextArea(
          controller: _jvmArgsController,
          hint: '-XX:+UseG1GC -XX:MaxGCPauseMillis=50',
          maxLines: 3,
        ),
      ],
    );
  }

  // ── Seção Launcher ────────────────────────────────────────────────────────────

  Widget _buildLauncherSection() {
    return _glassSection(
      children: [
        _contentHeader(_s.launcherTitle, _s.launcherSubtitle),
        _divider(),
        _subSectionTitle(_s.launcherBehavior, Icons.settings_rounded),
        const SizedBox(height: 8),
        _heliosSwitch(
          title: _s.launcherCloseOnLaunch,
          subtitle: _s.launcherCloseOnLaunchSub,
          value: _closeLauncherOnLaunch,
          onChanged: (v) => setState(() => _closeLauncherOnLaunch = v),
        ),
        _heliosSwitch(
          title: _s.launcherAutoUpdate,
          subtitle: _s.launcherAutoUpdateSub,
          value: _autoUpdateLauncher,
          onChanged: (v) => setState(() => _autoUpdateLauncher = v),
        ),
        _divider(),
        _subSectionTitle(_s.launcherLanguage, Icons.language_rounded),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s.launcherLanguageSub,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<AppLocale>(
                    value: _s.locale,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF1A1E2B),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    items: AppLocale.values.map((l) {
                      return DropdownMenuItem(
                        value: l,
                        child: Text('${l.flag}  ${l.displayName}'),
                      );
                    }).toList(),
                    onChanged: (l) {
                      if (l == null) return;
                      LocaleProvider.maybeOf(context)?.setLocale(l);
                      setState(() => _s = S(l));
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Seção Pastas ─────────────────────────────────────────────────────────────

  Widget _buildFoldersSection() {
    return FutureBuilder<String>(
      future: _getGameDir(),
      builder: (context, snap) {
        final gameDir = snap.data ?? '';
        final folders = [
          (icon: Icons.folder_rounded,             label: _s.folderGame,          path: gameDir),
          (icon: Icons.extension_rounded,          label: _s.folderMods,          path: '$gameDir/mods'),
          (icon: Icons.screenshot_monitor_rounded, label: _s.folderScreenshots,   path: '$gameDir/screenshots'),
          (icon: Icons.article_rounded,            label: _s.folderLogs,          path: '$gameDir/logs'),
          (icon: Icons.save_rounded,               label: _s.folderSaves,         path: '$gameDir/saves'),
          (icon: Icons.palette_rounded,            label: _s.folderResourcePacks, path: '$gameDir/resourcepacks'),
          (icon: Icons.wb_sunny_rounded,           label: _s.folderShaderpacks,   path: '$gameDir/shaderpacks'),
        ];

        return _glassSection(
          children: [
            _contentHeader(_s.foldersTitle, _s.foldersSubtitle),
            _divider(),
            if (gameDir.isEmpty)
              const Center(child: CircularProgressIndicator(color: _kAccent))
            else
              ...folders.map(
                (f) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _FolderRow(
                    icon: f.icon,
                    label: f.label,
                    path: f.path,
                    onTap: () => _openFolder(f.path),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ── Seção Sobre ──────────────────────────────────────────────────────────────

  Widget _buildAboutSection() {
    return _glassSection(
      children: [
        _contentHeader(_s.aboutTitle, _s.aboutSubtitle),
        _divider(),

        _subSectionTitle('CobbleHype Launcher', Icons.sports_esports_rounded),
        const SizedBox(height: 12),

        _infoRow(_s.aboutVersion, 'v$_appVersion'),
        _divider(padding: 12),
        _infoRow('Minecraft', kMinecraftVersion),
        _divider(padding: 12),
        _infoRow('Fabric Loader', kFabricLoaderVersion),
        _divider(padding: 12),
        _infoRow(_s.aboutServer,
            kServerAddress.isNotEmpty ? kServerAddress : _s.aboutNotConfigured),
        const SizedBox(height: 24),

        if (_updateStatus.isNotEmpty) ...[
          _glassCard(
            borderColor: _updateStatus.contains('disponível') ||
                    _updateStatus.contains('available')
                ? _kAccent.withValues(alpha: 0.30)
                : null,
            child: Text(
              _updateStatus,
              style: TextStyle(
                color: _updateStatus.contains('disponível') ||
                        _updateStatus.contains('available')
                    ? _kAccent
                    : Colors.white70,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],

        _HeliosOutlineButton(
          label: _s.aboutCheckUpdates,
          icon: Icons.update_rounded,
          loading: _checkingUpdate,
          onTap: _checkingUpdate ? null : _checkForUpdates,
        ),

        if (kGithubRepo.isNotEmpty) ...[
          const SizedBox(height: 10),
          _HeliosOutlineButton(
            label: _s.aboutViewGithub,
            icon: Icons.code_rounded,
            onTap: () async {
              final uri = Uri.parse('https://github.com/$kGithubRepo');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ],
    );
  }

  // ── Helpers de layout ─────────────────────────────────────────────────────────

  Widget _glassCard({required Widget child, Color? borderColor}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: child,
    );
  }

  Widget _contentHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45), fontSize: 13)),
      ],
    );
  }

  Widget _divider({double padding = 20}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: padding),
      child: Container(height: 1, color: _kDivider),
    );
  }

  Widget _subSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _kAccent),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _ramSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final safeValue = value.clamp(min, max);
    final gb      = safeValue / 1024;
    final display = gb >= 1
        ? '${gb.toStringAsFixed(gb == gb.truncateToDouble() ? 0 : 1)} GB'
        : '${safeValue.toInt()} MB';

    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65), fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: safeValue,
            min: min,
            max: max,
            divisions: ((max - min) / 512).round().clamp(1, 999),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(display,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: _kAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      ],
    );
  }

  Widget _heliosSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.40),
                        fontSize: 12)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _javaPathField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kDivider),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Icon(Icons.coffee_rounded, color: Colors.white54, size: 18),
          ),
          Expanded(
            child: TextField(
              controller: _javaPathController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: Platform.isWindows
                    ? r'C:\Program Files\Java\jdk-21\bin\java.exe'
                    : '/usr/lib/jvm/java-21/bin/java',
                hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _javaPathController.clear()),
            child: Text(_s.gameJavaClear,
                style: const TextStyle(color: _kAccent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _darkTextArea({
    required TextEditingController controller,
    required String hint,
    int maxLines = 2,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _kAccent, width: 1.5),
        ),
      ),
    );
  }

  Widget _darkField({
    required TextEditingController controller,
    required String hint,
    required String suffix,
    required double width,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
              color: Colors.white.withValues(alpha: 0.30), fontSize: 12),
          suffixText: suffix,
          suffixStyle:
              TextStyle(color: Colors.white.withValues(alpha: 0.40), fontSize: 12),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _kDivider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _kDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _kAccent, width: 1.5),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55), fontSize: 13)),
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widgets auxiliares
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Skin Body 3D (corpo inteiro com rotação mouse-tracking) ─────────────────

class _SkinBody3D extends StatefulWidget {
  final String skinUrl;
  final double size;
  const _SkinBody3D({required this.skinUrl, this.size = 220});

  @override
  State<_SkinBody3D> createState() => _SkinBody3DState();
}

class _SkinBody3DState extends State<_SkinBody3D> {
  double _rotY = 0;
  static const double _maxAngle = 0.18;

  void _onHover(PointerEvent event) {
    final center = widget.size / 2;
    setState(() {
      _rotY = ((event.localPosition.dx - center) / center).clamp(-1.0, 1.0);
    });
  }

  void _onExit(PointerEvent _) => setState(() => _rotY = 0);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: _onHover,
      onExit: _onExit,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: _rotY),
        duration: const Duration(milliseconds: 150),
        builder: (_, animRotY, child) {
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(animRotY * _maxAngle),
            child: child,
          );
        },
        child: Container(
          width: widget.size * 0.55,
          height: widget.size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Image.network(
            widget.skinUrl,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: const Center(
                child: Icon(Icons.person_rounded,
                    color: Colors.white24, size: 64),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Stat Card ───────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: _kAccent.withValues(alpha: 0.7)),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.40),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sidebar Icon Button ────────────────────────────────────────────────────

class _SidebarIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _SidebarIconButton({required this.icon, required this.tooltip, required this.onTap});
  @override
  State<_SidebarIconButton> createState() => _SidebarIconButtonState();
}

class _SidebarIconButtonState extends State<_SidebarIconButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:  (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon,
                size: 18,
                color: _hovered ? Colors.white : Colors.white54),
          ),
        ),
      ),
    );
  }
}

// ─── Save Button ────────────────────────────────────────────────────────────

class _SaveButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _SaveButton({required this.label, required this.onTap});
  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: double.infinity,
          height: 40,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _hovered
                  ? [const Color(0xFF00E6A8), _kAccent]
                  : [_kAccent, const Color(0xFF00A87A)],
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: _kAccent.withValues(alpha: _hovered ? 0.40 : 0.15),
                blurRadius: _hovered ? 16 : 6,
              ),
            ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.80),
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Resolution Chip ────────────────────────────────────────────────────────

class _ResChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ResChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? _kAccent.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? _kAccent.withValues(alpha: 0.60)
                : Colors.white.withValues(alpha: 0.10),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _kAccent : Colors.white60,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ─── Folder Row ─────────────────────────────────────────────────────────────

class _FolderRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String path;
  final VoidCallback onTap;
  const _FolderRow({required this.icon, required this.label, required this.path, required this.onTap});
  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kDivider),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: _kAccent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(widget.path,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 11)),
                  ],
                ),
              ),
              Icon(Icons.open_in_new_rounded,
                  size: 15,
                  color: _hovered
                      ? Colors.white70
                      : Colors.white.withValues(alpha: 0.30)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Destructive Button ─────────────────────────────────────────────────────

class _DestructiveButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _DestructiveButton({required this.label, required this.icon, required this.onTap});
  @override
  State<_DestructiveButton> createState() => _DestructiveButtonState();
}

class _DestructiveButtonState extends State<_DestructiveButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.redAccent.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered
                  ? Colors.redAccent.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.10),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: 16,
                  color: _hovered ? Colors.redAccent : Colors.white60),
              const SizedBox(width: 8),
              Text(widget.label,
                  style: TextStyle(
                      color: _hovered ? Colors.redAccent : Colors.white60,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Helios Outline Button ──────────────────────────────────────────────────

class _HeliosOutlineButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback? onTap;
  const _HeliosOutlineButton({required this.label, required this.icon, this.loading = false, this.onTap});
  @override
  State<_HeliosOutlineButton> createState() => _HeliosOutlineButtonState();
}

class _HeliosOutlineButtonState extends State<_HeliosOutlineButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered && enabled
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered && enabled
                  ? Colors.white.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.10),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.loading
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _kAccent))
                  : Icon(widget.icon, size: 16, color: Colors.white70),
              const SizedBox(width: 8),
              Text(widget.label,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
