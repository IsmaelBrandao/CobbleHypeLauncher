# CobbleHype Launcher

## O que e
Launcher customizado para o modpack CobbleHype, hospedado no CurseForge (primario) com fallback Modrinth.
Motor: Fabric Loader 0.18.6 + Minecraft 1.21.1. Java: gerenciado automaticamente (JRE 21 via Adoptium).
Plataformas: Windows, Linux, macOS, Android (via PojavLauncher).

## Stack
- **Flutter 3.41+ (Dart)** — UI e logica, um codebase para todas as plataformas
- **Material 3** — design system, tema escuro como padrao
- `http` — chamadas REST (CurseForge curse.tools, Modrinth, Adoptium, Microsoft OAuth)
- `shared_preferences` — preferencias do usuario, caminho JRE, versao do modpack
- `flutter_secure_storage` — tokens OAuth sensiveis (Keychain/Keystore/DPAPI)
- `path_provider` — localizar pastas do sistema (AppData, home, etc.)
- `crypto` — validar SHA-256 e SHA-1 dos arquivos baixados (streaming incremental)
- `archive` / `archive_io` — extrair .zip e .tar.gz (JRE, natives, modpack ZIP)
- `package_info_plus` — versao do launcher para auto-update via GitHub Releases
- `url_launcher` — abrir browser para OAuth e links externos
- `webview_windows` — WebView embutido para login Microsoft no Windows
- `window_manager` — gerenciar janela desktop (titulo, tamanho minimo)
- `font_awesome_flutter` — icones (Microsoft, Discord, etc.)

## Estrutura de pastas
```
lib/
  main.dart                    <- entry point, MaterialApp, tema, rota inicial
  l10n/
    app_strings.dart           <- todas as strings i18n (pt-BR, en-US, es-ES)
    locale_provider.dart       <- provider de locale, helper sOf(context)
  screens/
    welcome_screen.dart        <- onboarding (selecao de idioma)
    language_screen.dart       <- tela de troca de idioma
    login_screen.dart          <- Microsoft OAuth (WebView no Win, browser externo em outros)
    webview_login_dialog.dart  <- dialog com WebView2 embutido (Windows only)
    home_screen.dart           <- Play button, status, console de log, particulas
    settings_screen.dart       <- RAM, resolucao, caminho Java, auto-update, etc.
  services/
    auth_service.dart          <- OAuth 2.0 Microsoft (PKCE) -> Xbox Live -> XSTS -> Minecraft
    java_manager.dart          <- Download JRE 21 via Adoptium (streaming + hash incremental)
    update_engine.dart         <- Sync de mods CurseForge/Modrinth, delta update, streaming
    launch_engine.dart         <- Instala Fabric, monta classpath, lanca Minecraft
    asset_manager.dart         <- Download de assets do Minecraft (texturas, sons)
    launcher_updater.dart      <- Auto-update do launcher via GitHub Releases API
    server_status_service.dart <- Ping do servidor Minecraft (SLP protocol)
    play_time_service.dart     <- Tracking de tempo de jogo
    logger_service.dart        <- Log em arquivo + console
    skin_cache.dart            <- Cache local de skins/avatares
    android_launcher.dart      <- Integracao com PojavLauncher (Android)
    pref_keys.dart             <- Enum type-safe para chaves SharedPreferences
  models/
    modpack.dart               <- Constantes do modpack + ModFile/ModpackVersion
    minecraft_account.dart     <- Model da conta (username, uuid, token, offline flag)
```

## Configuracao do modpack
```dart
// lib/models/modpack.dart
const String kModpackId = 'SEU_MODPACK_ID_MODRINTH';     // ID no Modrinth (fallback)
const String kFabricLoaderVersion = '0.18.6';
const String kMinecraftVersion = '1.21.1';
const String kCurseForgeSlug = 'cobblehype';
const int kCurseForgeProjectId = 1489887;                 // Fonte primaria
const String kCurseForgeApiKey = '';                       // Vazio = usa curse.tools (sem key)
const String kServerAddress = 'play.cobblehype.com';
const String kGithubRepo = 'IsmaelBrandao/CobbleHypeLauncher';
```

## Convencoes de codigo
- Dart idiomatico: `async/await`, sem callbacks desnecessarios
- Nenhuma logica de negocio dentro de widgets — tudo em `services/`
- Nomes de arquivos e variaveis em ingles, comentarios em portugues quando util
- Downloads grandes: SEMPRE streaming para disco (nunca buffer 100MB+ na RAM)
- Hash validation: incremental via `startChunkedConversion` + `_DigestSink`
- Downloads em lotes: `Future.wait` com batch size 8 (paralelo controlado)
- Tokens sensiveis: `FlutterSecureStorage`, nunca em `SharedPreferences`
- PrefKeys: usar enum `PrefKey` em vez de strings literais
- Android: integracao com PojavLauncher via Android Intent (nao baixa JRE)

## APIs utilizadas
- **CurseForge (primario):** `https://api.curse.tools/v1/cf` (proxy publico, sem key)
- **CurseForge CDN:** `https://mediafilez.forgecdn.net/files/{id/1000}/{id%1000}/{filename}`
- **Modrinth (fallback):** `https://api.modrinth.com/v2/project/{id}/version`
- **Adoptium (JRE):** `https://api.adoptium.net/v3/assets/latest/21/hotspot`
- **Fabric Meta:** `https://meta.fabricmc.net/v2/versions/loader/{mc}/{loader}/profile/json`
- **Microsoft OAuth:** Authorization Code + PKCE via `login.microsoftonline.com/consumers`
- **Xbox Live + XSTS:** cadeia completa para obter token Minecraft

## Launch Engine
O Fabric Loader e mais simples que NeoForge: sem installer.jar.
O LaunchEngine baixa o profile JSON via Fabric Meta API e usa `inheritsFrom: "1.21.1"`.
Main class: `net.fabricmc.loader.impl.launch.knot.KnotClient`
Args condicionais (rule-based) avaliados por plataforma.
`${user_type}` = "msa" (online) ou "legacy" (offline).
