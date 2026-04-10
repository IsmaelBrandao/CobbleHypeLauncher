import 'package:shared_preferences/shared_preferences.dart';

import 'pref_keys.dart';

/// Rastreia o tempo jogado e métricas de uso do launcher.
/// Chame [startSession] quando o jogo iniciar e [endSession] quando fechar.
class PlayTimeService {
  static Future<SharedPreferences>? _prefsFuture;

  DateTime? _sessionStart;

  Future<SharedPreferences> _prefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  bool get isPlaying => _sessionStart != null;

  void startSession() {
    _sessionStart = DateTime.now();
  }

  Future<void> endSession() async {
    if (_sessionStart == null) return;
    final minutes = DateTime.now().difference(_sessionStart!).inMinutes;
    _sessionStart = null;
    if (minutes <= 0) return;

    final prefs = await _prefs();
    final total = prefs.getInt(PrefKey.totalPlayMinutes.key) ?? 0;
    await prefs.setInt(PrefKey.totalPlayMinutes.key, total + minutes);

    // Incrementa contador de sessões
    final sessions = prefs.getInt(PrefKey.sessionCount.key) ?? 0;
    await prefs.setInt(PrefKey.sessionCount.key, sessions + 1);

    // Salva data da primeira vez jogada
    if (!prefs.containsKey(PrefKey.firstPlayed.key)) {
      await prefs.setString(
          PrefKey.firstPlayed.key, DateTime.now().toIso8601String());
    }
  }

  Future<int> getTotalMinutes() async {
    final prefs = await _prefs();
    return prefs.getInt(PrefKey.totalPlayMinutes.key) ?? 0;
  }

  Future<int> getSessionCount() async {
    final prefs = await _prefs();
    return prefs.getInt(PrefKey.sessionCount.key) ?? 0;
  }

  Future<DateTime?> getFirstPlayed() async {
    final prefs = await _prefs();
    final s = prefs.getString(PrefKey.firstPlayed.key);
    return s != null ? DateTime.tryParse(s) : null;
  }

  /// Registra que o launcher foi aberto (chamar no initState do app)
  Future<void> markLauncherOpened() async {
    final prefs = await _prefs();
    await prefs.setString(
        PrefKey.launcherOpened.key, DateTime.now().toIso8601String());
  }

  /// Registra tempo acumulado com o launcher aberto (chamar no dispose do app)
  Future<void> markLauncherClosed() async {
    final prefs = await _prefs();
    final opened = prefs.getString(PrefKey.launcherOpened.key);
    if (opened == null) return;

    final start = DateTime.tryParse(opened);
    if (start == null) return;

    final minutes = DateTime.now().difference(start).inMinutes;
    if (minutes <= 0) return;

    final total = prefs.getInt(PrefKey.launcherMinutes.key) ?? 0;
    await prefs.setInt(PrefKey.launcherMinutes.key, total + minutes);
    await prefs.remove(PrefKey.launcherOpened.key);
  }

  Future<int> getLauncherMinutes() async {
    final prefs = await _prefs();
    return prefs.getInt(PrefKey.launcherMinutes.key) ?? 0;
  }

  /// Retorna todas as métricas de uma vez
  Future<PlayStats> getStats() async {
    final prefs = await _prefs();
    final firstStr = prefs.getString(PrefKey.firstPlayed.key);
    return PlayStats(
      totalPlayMinutes: prefs.getInt(PrefKey.totalPlayMinutes.key) ?? 0,
      sessionCount: prefs.getInt(PrefKey.sessionCount.key) ?? 0,
      firstPlayed: firstStr != null ? DateTime.tryParse(firstStr) : null,
      launcherMinutes: prefs.getInt(PrefKey.launcherMinutes.key) ?? 0,
    );
  }

  static String format(int minutes) {
    if (minutes < 60) return '${minutes}min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m > 0 ? '${h}h ${m}min' : '${h}h';
  }
}

class PlayStats {
  final int totalPlayMinutes;
  final int sessionCount;
  final DateTime? firstPlayed;
  final int launcherMinutes;

  const PlayStats({
    required this.totalPlayMinutes,
    required this.sessionCount,
    required this.firstPlayed,
    required this.launcherMinutes,
  });
}
