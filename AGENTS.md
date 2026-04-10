# CobbleHype Launcher

## O que é
Launcher customizado para um único modpack hospedado no servidor CobbleHype.
Suporta atualizações automáticas via Modrinth (primário) e CurseForge (fallback).
Motor: Fabric 1.21.1. Java: gerenciado automaticamente pelo launcher (JRE 21 via Adoptium).
Plataformas: Windows, Linux, macOS, Android.

## Stack
- **Flutter (Dart)** — UI e lógica, um codebase para todas as plataformas
- **Material 3** — design system, tema escuro como padrão
- `http` — chamadas REST (Modrinth API, CurseForge API, Adoptium API, Microsoft OAuth)
- `shared_preferences` — preferências do usuário, caminho do JRE e tokens OAuth em cache
- `path_provider` — localizar pastas do sistema (AppData, home, etc.)
- `crypto` — validar SHA-256 e SHA-1 dos arquivos baixados
- `archive` — extrair .zip e .tar.gz (JRE)
- `package_info_plus` — versão do launcher para futuro auto-update
- `url_launcher` — abrir browser para OAuth device code flow

## Estrutura de pastas
```
lib/
  main.dart                    ← entry point, MaterialApp, tema
  screens/
    login_screen.dart          ← Microsoft OAuth, device code flow
    home_screen.dart           ← Play button, status de update, banner do modpack
    settings_screen.dart       ← RAM, resolução, caminho do Java
  services/
    auth_service.dart          ← OAuth 2.0 Microsoft → token Minecraft
    java_manager.dart          ← Download JRE 21 via Adoptium, detecção de plataforma
    update_engine.dart         ← Sync de mods via Modrinth/CurseForge, delta update
    launch_engine.dart         ← Lançar Fabric Loader com JVM gerenciada pelo launcher
  models/
    modpack.dart               ← Model do modpack (id, versão, lista de mods)
    minecraft_account.dart     ← Model da conta (username, uuid, access_token)
assets/
  images/
    banner.png                 ← Banner do modpack (1280x360px recomendado)
    logo.png                   ← Logo do servidor
  fonts/                       ← Fontes customizadas (opcional)
test/
  java_manager_test.dart
  update_engine_test.dart
```

## Convenções de código
- Dart idiomático: `async/await`, sem callbacks desnecessários
- Nenhuma lógica de negócio dentro de widgets — tudo em `services/`
- Nomes de arquivos e variáveis em inglês, comentários em português quando útil
- Widgets são `StatelessWidget` sempre que possível; estado gerenciado via `StatefulWidget` ou `ValueNotifier`
- Android: integração com PojavLauncher via Android Intent (não baixa JRE próprio no Android)

## Configuração do modpack (alterar aqui quando mudar)
```dart
// lib/models/modpack.dart
const String kModpackId = 'SEU_MODPACK_ID_MODRINTH';     // ID no Modrinth
const String kFabricLoaderVersion = '0.18.6';             // Versão do Fabric Loader
const String kMinecraftVersion = '1.21.1';
```

## Fluxo de uso (do ponto de vista do jogador)
1. Abre o launcher → tela de login Microsoft
2. Login feito → fica salvo, não precisa logar de novo
3. Launcher verifica atualizações de mods em background
4. Se houver update: barra de progresso "Atualizando mods (X/Y)"
5. Primeira abertura: também baixa JRE 21 automaticamente (~180MB)
6. Botão PLAY ativa → jogo abre

## Comandos úteis
```bash
flutter run                      # Rodar no desktop/emulador
flutter run -d android           # Rodar no Android
flutter build windows            # Build Windows
flutter build linux              # Build Linux
flutter build macos              # Build macOS
flutter build apk                # Build Android (.apk)
flutter pub get                  # Instalar dependências
flutter test                     # Rodar testes
flutter doctor                   # Verificar ambiente
```

## APIs utilizadas
- **Adoptium (JRE):** `https://api.adoptium.net/v3/assets/latest/21/hotspot`
- **Fabric Meta:** `https://meta.fabricmc.net/v2/versions/loader/{mc_version}/{loader_version}/profile/json`
- **Modrinth:** `https://api.modrinth.com/v2/project/{id}/version`
- **Microsoft OAuth:** Device Code Flow via `https://login.microsoftonline.com`
- **Xbox Live + XSTS:** para obter token Minecraft
- **Minecraft Services:** `https://api.minecraftservices.com/authentication/login_with_xbox`

## Notas de plataforma
- **Windows:** JRE extraído em `%APPDATA%/CobbleHypeLauncher/runtime/jre21/`
- **Linux/macOS:** JRE extraído em `~/.cobblehype/runtime/jre21/`
- **Android:** Não baixa JRE — delega ao PojavLauncher via Intent com extras de conta e modpack
- **Java mínimo para Fabric 1.21.1:** Java 21 (obrigatório)

## Ponto de atenção: Launch Engine
O Fabric Loader é mais simples que o NeoForge: sem installer.jar.
O LaunchEngine baixa o profile JSON via Fabric Meta API e usa `inheritsFrom: "1.21.1"` para
incluir as libraries do vanilla no classpath.
Main class: `net.fabricmc.loader.impl.launch.knot.KnotClient`
Referência: código-fonte do Prism Launcher (C++) e MultiMC.
