/// Chaves type-safe para SharedPreferences.
/// Use estas constantes em vez de strings literais para evitar typos.
///
/// Tokens sensíveis (access_token, refresh_token) ficam no FlutterSecureStorage
/// e não têm entradas aqui.
enum PrefKey {
  // ── Conta (dados não-sensíveis) ──────────────────────────────────────────
  username('minecraft_username'),
  uuid('minecraft_uuid'),
  tokenExpiresAt('token_expires_at'),
  accountIsOffline('account_is_offline'),

  // ── Configurações de jogo ─────────────────────────────────────────────────
  minRam('ram_min_mb'),
  maxRam('ram_max_mb'),
  resolution('resolution'),
  fullscreen('fullscreen'),
  jvmArgsExtra('jvm_args_extra'),
  javaPathOverride('java_path_override'),
  closeOnLaunch('close_on_launch'),
  autoUpdateLauncher('auto_update_launcher'),
  gameDirectory('game_directory'),

  // ── Java gerenciado ───────────────────────────────────────────────────────
  javaPath('java_path'),

  // ── Tempo de jogo ─────────────────────────────────────────────────────────
  totalPlayMinutes('total_play_minutes'),
  sessionCount('play_session_count'),
  firstPlayed('first_played_at'),
  launcherMinutes('total_launcher_minutes'),
  launcherOpened('launcher_opened_at'),

  // ── Estado de update ──────────────────────────────────────────────────────
  modpackVersion('modpack_version'),

  // ── Onboarding e locale ───────────────────────────────────────────────────
  onboardingDone('onboarding_done'),
  locale('app_locale');

  const PrefKey(this.key);

  /// String exata usada no SharedPreferences.
  final String key;
}
