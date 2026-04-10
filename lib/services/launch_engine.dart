import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/minecraft_account.dart';
import '../models/modpack.dart';
import 'asset_manager.dart';
import 'logger_service.dart';
import 'pref_keys.dart';

/// Informações de um crash do jogo — código de saída e últimas linhas de log.
class GameCrashInfo {
  final int exitCode;
  final String lastLog;

  const GameCrashInfo({required this.exitCode, required this.lastLog});
}

/// Exceção lançada pelo LaunchEngine quando o jogo termina com código != 0.
class GameCrashException implements Exception {
  final GameCrashInfo crash;

  const GameCrashException(this.crash);

  @override
  String toString() =>
      'GameCrashException: exitCode=${crash.exitCode}';
}

/// Lança o Minecraft 1.21.1 com Fabric Loader.
///
/// Fluxo:
/// 1. installFabric() — baixa profile JSON + libraries do Fabric via Fabric Meta API
/// 2. launch() — monta classpath (vanilla + fabric) e lança o jogo
///
/// Fabric é muito mais simples que NeoForge: sem installer.jar.
/// O profile JSON herda (`inheritsFrom`) da versão vanilla, então precisamos
/// das libraries do vanilla também.
class LaunchEngine {
  // Buffer circular de linhas de log — máx. 500 linhas (FIFO)
  static const int _logBufferMax = 500;
  final List<String> _logBuffer = [];
  static const String _fabricMetaBase =
      'https://meta.fabricmc.net/v2/versions/loader';

  /// Retorna true se o Fabric Loader já está instalado
  Future<bool> isFabricInstalled() async {
    final versionsDir = await _getVersionsDir();
    const versionId =
        'fabric-loader-$kFabricLoaderVersion-$kMinecraftVersion';
    final versionJson =
        File('${versionsDir.path}/$versionId/$versionId.json');
    return versionJson.exists();
  }

  /// Instala o Fabric Loader — baixa profile JSON e todas as libraries.
  /// Também baixa o vanilla 1.21.1 JSON e client.jar (necessários para herança).
  Future<void> installFabric({
    void Function(String status, double progress)? onProgress,
  }) async {
    final gameDir = await _getGameDir();
    final versionsDir = await _getVersionsDir();
    final librariesDir = Directory('${gameDir.path}/libraries');
    if (!await librariesDir.exists()) {
      await librariesDir.create(recursive: true);
    }

    const versionId =
        'fabric-loader-$kFabricLoaderVersion-$kMinecraftVersion';
    final versionDir = Directory('${versionsDir.path}/$versionId');
    if (!await versionDir.exists()) {
      await versionDir.create(recursive: true);
    }

    // 1. Baixa o profile JSON do Fabric Meta API
    onProgress?.call('Baixando perfil do Fabric Loader...', 0.0);
    const profileUrl =
        '$_fabricMetaBase/$kMinecraftVersion/$kFabricLoaderVersion/profile/json';
    final profileResp = await http.get(
      Uri.parse(profileUrl),
      headers: {'User-Agent': 'CobbleHypeLauncher/1.0'},
    );

    if (profileResp.statusCode != 200) {
      throw Exception(
          'Erro ao baixar perfil Fabric: ${profileResp.statusCode}\nURL: $profileUrl');
    }

    final profileJson =
        jsonDecode(profileResp.body) as Map<String, dynamic>;

    // Salva o profile JSON localmente
    final versionFile = File('${versionDir.path}/$versionId.json');
    await versionFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(profileJson));

    // 2. Baixa as libraries do Fabric (paralelo em lotes de 8)
    const batchSize = 8;
    final fabricLibs = profileJson['libraries'] as List? ?? [];
    for (int i = 0; i < fabricLibs.length; i += batchSize) {
      final batch = fabricLibs.sublist(
          i, (i + batchSize).clamp(0, fabricLibs.length));
      await Future.wait(batch.map((lib) async {
        final libMap = lib as Map<String, dynamic>;
        final name = libMap['name'] as String;
        final baseUrl =
            libMap['url'] as String? ?? 'https://maven.fabricmc.net/';
        await _downloadMavenLibrary(name, baseUrl, librariesDir);
      }));
      final done = (i + batch.length).clamp(0, fabricLibs.length);
      onProgress?.call(
        'Baixando libraries Fabric... $done/${fabricLibs.length}',
        0.1 + done / (fabricLibs.length + 1) * 0.5,
      );
    }

    // 3. Baixa vanilla 1.21.1 JSON, client.jar e libraries (necessário para inheritsFrom)
    onProgress?.call('Baixando Minecraft $kMinecraftVersion...', 0.65);
    await _ensureVanillaAssets(gameDir, versionsDir, librariesDir, onProgress);

    onProgress?.call('Fabric Loader instalado!', 1.0);
  }

  /// Converte nome Maven (group:artifact:version) para path relativo de arquivo.
  /// Ex: "org.ow2.asm:asm:9.9" → "org/ow2/asm/asm/9.9/asm-9.9.jar"
  String _mavenNameToPath(String name) {
    final parts = name.split(':');
    if (parts.length < 3) {
      throw Exception('Nome Maven inválido: $name');
    }
    final group = parts[0].replaceAll('.', '/');
    final artifact = parts[1];
    final version = parts[2];
    return '$group/$artifact/$version/$artifact-$version.jar';
  }

  /// Baixa uma library Maven se ainda não existir ou estiver vazia
  Future<void> _downloadMavenLibrary(
    String name,
    String baseUrl,
    Directory librariesDir,
  ) async {
    final path = _mavenNameToPath(name);
    final file = File('${librariesDir.path}/$path');

    // Pula se já existir com conteúdo
    if (await file.exists() && await file.length() > 0) return;

    await file.parent.create(recursive: true);

    final url = baseUrl.endsWith('/') ? '$baseUrl$path' : '$baseUrl/$path';
    final resp = await http.get(
      Uri.parse(url),
      headers: {'User-Agent': 'CobbleHypeLauncher/1.0'},
    );

    if (resp.statusCode != 200) {
      throw Exception(
          'Erro ao baixar library $name: ${resp.statusCode}\nURL: $url');
    }

    await file.writeAsBytes(resp.bodyBytes);
  }

  /// Garante que o vanilla 1.21.1 está disponível:
  /// - version JSON salvo em versions/1.21.1/1.21.1.json
  /// - client.jar salvo em versions/1.21.1/1.21.1.jar
  /// - libraries do vanilla baixadas em libraries/
  Future<void> _ensureVanillaAssets(
    Directory gameDir,
    Directory versionsDir,
    Directory librariesDir,
    void Function(String status, double progress)? onProgress,
  ) async {
    // Resolve URL do version JSON via manifest do Mojang
    final manifestResp = await http.get(
      Uri.parse(
          'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'),
      headers: {'User-Agent': 'CobbleHypeLauncher/1.0'},
    );
    if (manifestResp.statusCode != 200) {
      throw Exception(
          'Erro ao baixar version manifest: ${manifestResp.statusCode}');
    }

    final manifest =
        jsonDecode(manifestResp.body) as Map<String, dynamic>;
    final versions = manifest['versions'] as List;
    final entry = versions
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (v) => v['id'] == kMinecraftVersion,
          orElse: () =>
              throw Exception('MC $kMinecraftVersion não encontrado no manifest'),
        );

    final versionResp =
        await http.get(Uri.parse(entry['url'] as String));
    if (versionResp.statusCode != 200) {
      throw Exception(
          'Erro ao baixar version JSON do vanilla: ${versionResp.statusCode}');
    }

    final vanillaJson =
        jsonDecode(versionResp.body) as Map<String, dynamic>;

    // Salva o vanilla version JSON
    final vanillaDir =
        Directory('${versionsDir.path}/$kMinecraftVersion');
    if (!await vanillaDir.exists()) {
      await vanillaDir.create(recursive: true);
    }
    final vanillaJsonFile =
        File('${vanillaDir.path}/$kMinecraftVersion.json');
    await vanillaJsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(vanillaJson));

    // Baixa o client.jar
    final clientDownload =
        vanillaJson['downloads']?['client'] as Map<String, dynamic>?;
    if (clientDownload != null) {
      final clientJar =
          File('${vanillaDir.path}/$kMinecraftVersion.jar');
      if (!await clientJar.exists()) {
        onProgress?.call('Baixando Minecraft client.jar...', 0.70);
        final clientResp =
            await http.get(Uri.parse(clientDownload['url'] as String));
        if (clientResp.statusCode == 200) {
          await clientJar.writeAsBytes(clientResp.bodyBytes);
        } else {
          throw Exception(
              'Erro ao baixar client.jar: ${clientResp.statusCode}');
        }
      }
    }

    // Baixa as libraries do vanilla (artifact + classifier/natives)
    final vanillaLibs = vanillaJson['libraries'] as List? ?? [];
    final applicable = vanillaLibs
        .cast<Map<String, dynamic>>()
        .where(_libraryApplies)
        .toList();
    const batchSize = 8;

    // Determina o nome do classifier nativo da plataforma atual
    final nativeClassifier = Platform.isWindows
        ? 'natives-windows'
        : Platform.isMacOS
            ? 'natives-macos'
            : 'natives-linux';

    // Diretório de natives para extração de .dll/.so/.dylib
    final nativesDir = Directory('${gameDir.path}/natives');
    if (!await nativesDir.exists()) {
      await nativesDir.create(recursive: true);
    }

    for (int i = 0; i < applicable.length; i += batchSize) {
      final batch = applicable.sublist(
          i, (i + batchSize).clamp(0, applicable.length));
      await Future.wait(batch.map((lib) async {
        final downloads = lib['downloads'] as Map<String, dynamic>?;
        if (downloads == null) return;

        // Baixa o artifact principal (jar normal)
        final artifact = downloads['artifact'] as Map<String, dynamic>?;
        if (artifact != null) {
          final path = artifact['path'] as String;
          final url = artifact['url'] as String;
          final file = File('${librariesDir.path}/$path');

          if (!await file.exists() || await file.length() == 0) {
            await file.parent.create(recursive: true);
            final resp = await http.get(Uri.parse(url));
            if (resp.statusCode == 200) {
              await file.writeAsBytes(resp.bodyBytes);
            }
          }
        }

        // Estilo antigo: classifiers (ex: "natives-windows" dentro de downloads.classifiers)
        final classifiers = downloads['classifiers'] as Map<String, dynamic>?;
        if (classifiers != null && classifiers.containsKey(nativeClassifier)) {
          final nativeInfo = classifiers[nativeClassifier] as Map<String, dynamic>;
          final nativePath = nativeInfo['path'] as String;
          final nativeUrl = nativeInfo['url'] as String;
          final nativeFile = File('${librariesDir.path}/$nativePath');

          if (!await nativeFile.exists() || await nativeFile.length() == 0) {
            await nativeFile.parent.create(recursive: true);
            final resp = await http.get(Uri.parse(nativeUrl));
            if (resp.statusCode == 200) {
              await nativeFile.writeAsBytes(resp.bodyBytes);
            }
          }

          // Extrai .dll/.so/.dylib do JAR nativo para a pasta natives/
          await _extractNatives(nativeFile, nativesDir, lib);
        }

        // Estilo novo (MC 1.19.3+): o artifact normal JÁ É o JAR de natives
        final nativesField = lib['natives'] as Map<String, dynamic>?;
        final libName = lib['name'] as String? ?? '';
        final isNativeJar = nativesField != null ||
            libName.contains('natives-windows') ||
            libName.contains('natives-linux') ||
            libName.contains('natives-macos');

        if (isNativeJar && artifact != null && classifiers == null) {
          final artPath = artifact['path'] as String;
          final artFile = File('${librariesDir.path}/$artPath');
          await _extractNatives(artFile, nativesDir, lib);
        }
      }));

      final done = (i + batch.length).clamp(0, applicable.length);
      onProgress?.call(
        'Baixando libraries vanilla... $done/${applicable.length}',
        0.75 + done / applicable.length * 0.20,
      );
    }
  }

  /// Extrai arquivos nativos (.dll, .so, .dylib, .jnilib) de um JAR nativo para [nativesDir].
  Future<void> _extractNatives(
    File nativeJar,
    Directory nativesDir,
    Map<String, dynamic> lib,
  ) async {
    if (!await nativeJar.exists()) return;

    try {
      final bytes = await nativeJar.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Obtém lista de exclusão do manifesto ("extract.exclude")
      final extract = lib['extract'] as Map<String, dynamic>?;
      final exclude = (extract?['exclude'] as List?)
              ?.cast<String>()
              .toList() ??
          <String>[];

      for (final file in archive) {
        if (!file.isFile) continue;

        // Aplica exclusões (normalmente "META-INF/")
        final shouldExclude =
            exclude.any((prefix) => file.name.startsWith(prefix));
        if (shouldExclude) continue;

        // Só extrai binários nativos
        final name = file.name.toLowerCase();
        if (!name.endsWith('.dll') &&
            !name.endsWith('.so') &&
            !name.endsWith('.dylib') &&
            !name.endsWith('.jnilib')) {
          continue;
        }

        // Extrai usando só o nome do arquivo (sem subpastas do ZIP)
        final outName = file.name.contains('/')
            ? file.name.substring(file.name.lastIndexOf('/') + 1)
            : file.name;
        final outFile = File('${nativesDir.path}/$outName');

        if (!await outFile.exists()) {
          await outFile.writeAsBytes(file.content as List<int>);
        }
      }
    } catch (e) {
      await LoggerService.instance
          .warn('Falha ao extrair natives de ${nativeJar.path}: $e');
    }
  }

  /// Lança o jogo com o Fabric Loader.
  /// [javaPath] deve ser retornado pelo JavaManager.
  Future<void> launch({
    required String javaPath,
    required MinecraftAccount account,
    int ramMinMb = 512,
    int ramMb = 4096,
    String? jvmArgsExtra,
    String? resolution,
    bool fullscreen = false,
    bool ensureAssets = true,
    void Function(String log)? onLog,
    void Function(int done, int total, String asset)? onProgress,
    void Function()? onGameStarted,
    void Function()? onGameExit,
  }) async {
    final gameDir = await _getGameDir();
    final versionsDir = await _getVersionsDir();
    final librariesDir = Directory('${gameDir.path}/libraries');

    // Garante que os assets do Minecraft estão presentes antes de lançar
    if (ensureAssets) {
      try {
        final assetMgr = AssetManager();
        await assetMgr.ensureAssets(
          gameDir: gameDir.path,
          mcVersion: kMinecraftVersion,
          onProgress: (done, total, asset) {
            onProgress?.call(done, total, asset);
            onLog?.call('Assets: $done/$total');
          },
          onLog: onLog,
        );
      } catch (e) {
        // Falha no download de assets é logada mas não cancela o lançamento.
        // O jogo pode funcionar parcialmente ou mostrar texturas ausentes.
        onLog?.call('Aviso: erro ao garantir assets — $e');
      }
    }

    // Lê o Fabric profile JSON
    const versionId =
        'fabric-loader-$kFabricLoaderVersion-$kMinecraftVersion';
    final fabricJsonFile =
        File('${versionsDir.path}/$versionId/$versionId.json');

    if (!await fabricJsonFile.exists()) {
      throw Exception(
          'Fabric Loader não instalado. O launcher vai instalar automaticamente na próxima tentativa.');
    }

    final fabricJson =
        jsonDecode(await fabricJsonFile.readAsString()) as Map<String, dynamic>;

    // Lê o vanilla version JSON (inheritsFrom)
    final vanillaJsonFile =
        File('${versionsDir.path}/$kMinecraftVersion/$kMinecraftVersion.json');
    Map<String, dynamic>? vanillaJson;
    if (await vanillaJsonFile.exists()) {
      vanillaJson =
          jsonDecode(await vanillaJsonFile.readAsString()) as Map<String, dynamic>;
    }

    // Resolve o asset index ID real do vanilla JSON (ex: "1.21" para MC 1.21.1)
    final assetIndexId =
        vanillaJson?['assetIndex']?['id'] as String? ?? kMinecraftVersion;

    final args = _buildLaunchArgs(
      fabricJson: fabricJson,
      vanillaJson: vanillaJson,
      account: account,
      gameDir: gameDir,
      librariesDir: librariesDir,
      versionsDir: versionsDir,
      ramMinMb: ramMinMb,
      ramMb: ramMb,
      jvmArgsExtra: jvmArgsExtra,
      resolution: resolution,
      fullscreen: fullscreen,
      assetIndexId: assetIndexId,
    );

    onLog?.call(
        'Iniciando Minecraft $kMinecraftVersion com Fabric Loader $kFabricLoaderVersion...');

    // Limpa o buffer de log da sessão anterior
    _logBuffer.clear();

    final process = await Process.start(
      javaPath,
      args,
      workingDirectory: gameDir.path,
    );

    onGameStarted?.call();

    // Função auxiliar: adiciona linha ao buffer FIFO e repassa ao callback
    void handleLine(String line) {
      if (_logBuffer.length >= _logBufferMax) {
        _logBuffer.removeAt(0);
      }
      _logBuffer.add(line);
      onLog?.call(line);
    }

    // Combina stdout e stderr no mesmo buffer de log
    process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(handleLine);

    final exitCode = await process.exitCode;
    onGameExit?.call();

    // Se o jogo terminou com erro, lança exceção com as últimas 50 linhas
    if (exitCode != 0) {
      final lastLines = _logBuffer.length > 50
          ? _logBuffer.sublist(_logBuffer.length - 50)
          : List<String>.from(_logBuffer);
      throw GameCrashException(
        GameCrashInfo(
          exitCode: exitCode,
          lastLog: lastLines.join('\n'),
        ),
      );
    }
  }

  List<String> _buildLaunchArgs({
    required Map<String, dynamic> fabricJson,
    Map<String, dynamic>? vanillaJson,
    required MinecraftAccount account,
    required Directory gameDir,
    required Directory librariesDir,
    required Directory versionsDir,
    required int ramMinMb,
    required int ramMb,
    String? jvmArgsExtra,
    String? resolution,
    bool fullscreen = false,
    String assetIndexId = '1.21.1',
  }) {
    final args = <String>[];

    // Memória JVM
    args.addAll(['-Xms${ramMinMb}m', '-Xmx${ramMb}m']);

    // JVM args extras do usuário
    if (jvmArgsExtra != null && jvmArgsExtra.trim().isNotEmpty) {
      args.addAll(jvmArgsExtra.trim().split(RegExp(r'\s+')));
    }

    // JVM args do Fabric profile (ex: -DFabricMcEmu=...)
    final fabricJvmArgs =
        fabricJson['arguments']?['jvm'] as List? ?? [];
    _addConditionalArgs(fabricJvmArgs, args, account, gameDir, librariesDir, versionsDir, assetIndexId);

    // JVM args do vanilla (contêm -Djava.library.path, -Dos.name, etc.)
    if (vanillaJson != null) {
      final vanillaJvmArgs =
          vanillaJson['arguments']?['jvm'] as List? ?? [];
      _addConditionalArgs(vanillaJvmArgs, args, account, gameDir, librariesDir, versionsDir, assetIndexId);
    }

    // Classpath: libraries do Fabric + libraries do vanilla + client.jar
    final classpath =
        _buildClasspath(fabricJson, vanillaJson, librariesDir, versionsDir);
    args.addAll(['-cp', classpath]);

    // Main class vem do Fabric: net.fabricmc.loader.impl.launch.knot.KnotClient
    args.add(fabricJson['mainClass'] as String);

    // Game args do vanilla (--username, --version, --gameDir, --assetsDir, etc.)
    if (vanillaJson != null) {
      final vanillaGameArgs =
          vanillaJson['arguments']?['game'] as List? ?? [];
      _addConditionalArgs(vanillaGameArgs, args, account, gameDir, librariesDir, versionsDir, assetIndexId);
    }

    // Game args do Fabric (geralmente vazio, mas incluído por completude)
    final fabricGameArgs =
        fabricJson['arguments']?['game'] as List? ?? [];
    _addConditionalArgs(fabricGameArgs, args, account, gameDir, librariesDir, versionsDir, assetIndexId);

    // Resolução / tela cheia
    if (fullscreen) {
      args.add('--fullscreen');
    } else if (resolution != null && resolution.contains('x')) {
      final parts = resolution.split('x');
      if (parts.length == 2) {
        args.addAll(['--width', parts[0], '--height', parts[1]]);
      }
    }

    return args;
  }

  String _buildClasspath(
    Map<String, dynamic> fabricJson,
    Map<String, dynamic>? vanillaJson,
    Directory librariesDir,
    Directory versionsDir,
  ) {
    final separator = Platform.isWindows ? ';' : ':';
    // Set para evitar duplicatas no classpath
    final paths = <String>{};

    // 1. Libraries do Fabric (asm, sponge-mixin, intermediary, fabric-loader, etc.)
    final fabricLibs = fabricJson['libraries'] as List? ?? [];
    for (final lib in fabricLibs) {
      final name = (lib as Map<String, dynamic>)['name'] as String;
      final path = _mavenNameToPath(name);
      paths.add('${librariesDir.path}/$path');
    }

    // 2. Libraries do vanilla (LWJGL, log4j, brigadier, etc.)
    if (vanillaJson != null) {
      final vanillaLibs = vanillaJson['libraries'] as List? ?? [];
      for (final lib in vanillaLibs) {
        final libMap = lib as Map<String, dynamic>;
        if (!_libraryApplies(libMap)) continue;
        final artifact =
            libMap['downloads']?['artifact'] as Map<String, dynamic>?;
        if (artifact != null) {
          final path = artifact['path'] as String;
          paths.add('${librariesDir.path}/$path');
        }
      }
    }

    // 3. Vanilla client.jar
    paths.add(
        '${versionsDir.path}/$kMinecraftVersion/$kMinecraftVersion.jar');

    return paths.join(separator);
  }

  /// Processa argumentos do Minecraft que podem ser strings diretas ou objetos
  /// com regras condicionais (ex: args específicos de Windows/macOS/Linux).
  /// Sem isso, args como -Dos.name=Windows 10 são silenciosamente descartados.
  void _addConditionalArgs(
    List<dynamic> argsList,
    List<String> target,
    MinecraftAccount account,
    Directory gameDir,
    Directory librariesDir,
    Directory versionsDir,
    String assetIndexId,
  ) {
    for (final arg in argsList) {
      if (arg is String) {
        target.add(_substituteVars(
            arg, account, gameDir, librariesDir, versionsDir, assetIndexId));
      } else if (arg is Map<String, dynamic>) {
        // Arg condicional com "rules" e "value"
        if (!_evaluateRules(arg['rules'] as List? ?? [])) continue;
        final value = arg['value'];
        if (value is String) {
          target.add(_substituteVars(
              value, account, gameDir, librariesDir, versionsDir, assetIndexId));
        } else if (value is List) {
          for (final v in value) {
            if (v is String) {
              target.add(_substituteVars(
                  v, account, gameDir, librariesDir, versionsDir, assetIndexId));
            }
          }
        }
      }
    }
  }

  /// Avalia regras do formato vanilla JSON (mesma lógica de _libraryApplies).
  bool _evaluateRules(List<dynamic> rules) {
    if (rules.isEmpty) return true;
    bool allowed = false;
    for (final rule in rules) {
      final ruleMap = rule as Map<String, dynamic>;
      final action = ruleMap['action'] as String;
      final os = ruleMap['os'] as Map<String, dynamic>?;
      final features = ruleMap['features'] as Map<String, dynamic>?;

      // Features como "is_demo_user" e "has_custom_resolution" —
      // ignoramos (nosso launcher não é demo e resolve resolução externamente)
      if (features != null) continue;

      if (os == null) {
        allowed = action == 'allow';
      } else {
        final osName = os['name'] as String?;
        final currentOs = Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
                ? 'osx'
                : 'linux';
        if (osName == null || osName == currentOs) {
          allowed = action == 'allow';
        }
      }
    }
    return allowed;
  }

  /// Verifica se uma library do vanilla se aplica à plataforma atual
  bool _libraryApplies(Map<String, dynamic> lib) {
    final rules = lib['rules'] as List?;
    if (rules == null) return true;

    bool allowed = false;
    for (final rule in rules) {
      final ruleMap = rule as Map<String, dynamic>;
      final action = ruleMap['action'] as String;
      final os = ruleMap['os'] as Map<String, dynamic>?;

      if (os == null) {
        allowed = action == 'allow';
      } else {
        final osName = os['name'] as String?;
        final currentOs = Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
                ? 'osx'
                : 'linux';
        if (osName == currentOs) {
          allowed = action == 'allow';
        }
      }
    }
    return allowed;
  }

  String _substituteVars(
    String template,
    MinecraftAccount account,
    Directory gameDir,
    Directory librariesDir,
    Directory versionsDir,
    String assetIndexId,
  ) {
    return template
        .replaceAll('\${auth_player_name}', account.username)
        .replaceAll('\${auth_uuid}', account.uuid)
        .replaceAll('\${auth_access_token}', account.accessToken)
        .replaceAll('\${user_type}', account.isOffline ? 'legacy' : 'msa')
        .replaceAll('\${auth_xuid}', '') // XUID não é obrigatório para launch
        .replaceAll('\${clientid}', _clientId)
        .replaceAll(
          '\${version_name}',
          'fabric-loader-$kFabricLoaderVersion-$kMinecraftVersion',
        )
        .replaceAll('\${game_directory}', gameDir.path)
        .replaceAll('\${assets_root}', '${gameDir.path}/assets')
        .replaceAll('\${assets_index_name}', assetIndexId)
        .replaceAll('\${version_type}', 'release')
        .replaceAll('\${library_directory}', librariesDir.path)
        .replaceAll(
          '\${classpath_separator}',
          Platform.isWindows ? ';' : ':',
        )
        .replaceAll(
          '\${natives_directory}',
          '${gameDir.path}/natives',
        )
        .replaceAll('\${launcher_name}', 'CobbleHypeLauncher')
        .replaceAll('\${launcher_version}', '1.0')
        .replaceAll('\${resolution_width}', '1280')
        .replaceAll('\${resolution_height}', '720');
  }

  // Client ID do Azure — mesmo usado no AuthService
  static const String _clientId = 'c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb';

  Future<Directory> _getGameDir() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString(PrefKey.gameDirectory.key);
    if (customPath != null) return Directory(customPath);

    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/minecraft');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _getVersionsDir() async {
    final gameDir = await _getGameDir();
    final dir = Directory('${gameDir.path}/versions');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
