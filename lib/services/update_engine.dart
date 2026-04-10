import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/modpack.dart';
import 'logger_service.dart';
import 'pref_keys.dart';

/// Sincroniza os mods do modpack usando CurseForge (primário) e Modrinth (fallback).
/// CurseForge usa a API pública curse.tools (sem API key) e CDN mediafilez.forgecdn.net.
/// Só baixa os mods que mudaram ou faltam — delta update.
class UpdateEngine {
  // ═══════════════════════════════════════════════════════════════════════════
  //  CONSTANTES
  // ═══════════════════════════════════════════════════════════════════════════

  static const String _modrinthBase = 'https://api.modrinth.com/v2';

  /// API pública que proxeia a CurseForge API — NÃO precisa de API key.
  static const String _curseToolsBase = 'https://api.curse.tools/v1/cf';

  /// CDN oficial do CurseForge — downloads diretos sem autenticação.
  static const String _forgeCdn = 'https://mediafilez.forgecdn.net';

  /// API oficial do CurseForge — usada apenas se o usuário fornecer API key.
  static const String _curseForgeBase = 'https://api.curseforge.com/v1';

  static const int _minecraftGameId = 432;

  static const Duration _httpTimeout = Duration(seconds: 30);
  static const Duration _downloadTimeout = Duration(seconds: 180);
  static const int _batchSize = 8;

  static const _userAgent = 'CobbleHypeLauncher/1.0 (contact@cobblehype.com)';

  // ═══════════════════════════════════════════════════════════════════════════
  //  API PÚBLICA
  // ═══════════════════════════════════════════════════════════════════════════

  /// Verifica e atualiza os mods.
  /// Tenta CurseForge primeiro (fonte primária); se falhar, usa Modrinth como fallback.
  Future<UpdateResult> syncMods({
    void Function(int done, int total, String currentMod)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    // CurseForge funciona se tem slug OU project ID (não precisa de API key!)
    final curseForgeOk =
        kCurseForgeSlug.isNotEmpty || kCurseForgeProjectId > 0;
    const modrinthOk = kModpackId != 'SEU_MODPACK_ID_MODRINTH';

    if (!curseForgeOk && !modrinthOk) {
      await LoggerService.instance.warn(
          'Sync ignorado: nem CurseForge nem Modrinth configurados.');
      return const UpdateResult(
          updated: false, modsDownloaded: 0, versionNumber: 'N/A');
    }

    await LoggerService.instance.info('Sync de mods iniciado');

    // Tenta CurseForge primeiro (fonte primária)
    if (curseForgeOk) {
      try {
        onStatus?.call('Verificando mods via CurseForge...');
        final result = await _syncFromCurseForge(
            onProgress: onProgress, onStatus: onStatus);
        return result;
      } catch (e) {
        await LoggerService.instance.warn('CurseForge falhou: $e');
        if (!modrinthOk) {
          if (_isNetworkError(e)) {
            onStatus?.call('Sem internet — usando mods existentes');
            return const UpdateResult(
                updated: false, modsDownloaded: 0, versionNumber: 'offline');
          }
          rethrow;
        }
        await LoggerService.instance.info('Tentando fallback Modrinth...');
      }
    }

    // Fallback: Modrinth
    if (modrinthOk) {
      try {
        onStatus?.call('Verificando mods via Modrinth...');
        return await _syncFromModrinth(
            onProgress: onProgress, onStatus: onStatus);
      } catch (e) {
        await LoggerService.instance.error('Modrinth também falhou: $e');
        if (_isNetworkError(e)) {
          onStatus?.call('Sem internet — usando mods existentes');
          return const UpdateResult(
              updated: false, modsDownloaded: 0, versionNumber: 'offline');
        }
        rethrow;
      }
    }

    return const UpdateResult(
        updated: false, modsDownloaded: 0, versionNumber: 'N/A');
  }

  /// Retorna true se há uma versão mais nova que a local.
  /// Otimizado para ser rápido: 1 request (sem check de online separado).
  Future<bool> hasUpdate() async {
    final curseForgeOk =
        kCurseForgeSlug.isNotEmpty || kCurseForgeProjectId > 0;
    const modrinthOk = kModpackId != 'SEU_MODPACK_ID_MODRINTH';
    if (!curseForgeOk && !modrinthOk) return false;

    final prefs = await SharedPreferences.getInstance();
    final localVersion =
        prefs.getString(PrefKey.modpackVersion.key) ?? '';

    // Tenta CurseForge direto (1 único request — o próprio request já serve de teste de conectividade)
    if (curseForgeOk) {
      try {
        final useOfficialApi = kCurseForgeApiKey.isNotEmpty;
        final baseUrl = useOfficialApi ? _curseForgeBase : _curseToolsBase;
        final headers =
            useOfficialApi ? _cfOfficialHeaders() : _cfPublicHeaders();
        final latestFile = await _fetchCfLatestFile(
            kCurseForgeProjectId > 0 ? kCurseForgeProjectId : await _resolveCfProjectId(baseUrl, headers),
            baseUrl,
            headers);
        final remoteVersion = latestFile['displayName'] as String? ?? '';
        return remoteVersion != localVersion;
      } catch (_) {
        if (!modrinthOk) return false;
      }
    }

    // Fallback Modrinth
    if (modrinthOk) {
      try {
        final latest = await _fetchModrinthLatest();
        return latest.versionNumber != localVersion;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MODRINTH
  // ═══════════════════════════════════════════════════════════════════════════

  Future<UpdateResult> _syncFromModrinth({
    void Function(int, int, String)? onProgress,
    void Function(String)? onStatus,
  }) async {
    final latestVersion = await _fetchModrinthLatest();
    return _applyUpdate(latestVersion,
        onProgress: onProgress, onStatus: onStatus);
  }

  Future<ModpackVersion> _fetchModrinthLatest() async {
    final url = Uri.parse(
        '$_modrinthBase/project/$kModpackId/version?game_versions=["$kMinecraftVersion"]&loaders=["fabric"]');

    final response = await http
        .get(url, headers: {'User-Agent': _userAgent})
        .timeout(_httpTimeout);

    if (response.statusCode != 200) {
      throw Exception('Modrinth HTTP ${response.statusCode}');
    }

    final List<dynamic> versions = jsonDecode(response.body) as List;
    if (versions.isEmpty) {
      throw Exception('Nenhuma versão encontrada no Modrinth.');
    }

    return ModpackVersion.fromModrinthJson(
        versions.first as Map<String, dynamic>);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CURSEFORGE (via curse.tools — sem API key!)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<UpdateResult> _syncFromCurseForge({
    void Function(int, int, String)? onProgress,
    void Function(String)? onStatus,
  }) async {
    final useOfficialApi = kCurseForgeApiKey.isNotEmpty;
    final baseUrl = useOfficialApi ? _curseForgeBase : _curseToolsBase;
    final headers = useOfficialApi ? _cfOfficialHeaders() : _cfPublicHeaders();

    // 1. Resolve o project ID
    final modId = await _resolveCfProjectId(baseUrl, headers);

    // 2. Busca info do último arquivo (leve — só metadata, não baixa o ZIP)
    final latestFile = await _fetchCfLatestFile(modId, baseUrl, headers);
    final remoteDisplayName = latestFile['displayName'] as String? ?? 'Unknown';

    // 3. Verifica se já temos essa versão + os mods baixados
    final prefs = await SharedPreferences.getInstance();
    final localVersion = prefs.getString(PrefKey.modpackVersion.key) ?? '';
    final modsDir = await _getModsDir();
    final localModCount = await modsDir
        .list()
        .where((e) => e.path.endsWith('.jar'))
        .length;

    if (localVersion == remoteDisplayName && localModCount > 0) {
      await LoggerService.instance
          .info('CurseForge: versão "$remoteDisplayName" já instalada ($localModCount mods). Nada a fazer.');
      onStatus?.call('Mods atualizados!');
      return UpdateResult(
        updated: false,
        modsDownloaded: 0,
        versionNumber: remoteDisplayName,
      );
    }

    await LoggerService.instance.info(
        'CurseForge: atualização necessária. Local="$localVersion" ($localModCount mods), Remoto="$remoteDisplayName"');

    // 4. Agora sim: baixa o ZIP, extrai manifest e resolve os mods
    onStatus?.call('Baixando modpack do CurseForge...');
    final latestVersion = await _parseCurseForgeFile(
        latestFile, baseUrl, headers);
    return _applyUpdate(latestVersion,
        onProgress: onProgress, onStatus: onStatus);
  }

  /// Resolve o project ID do modpack no CurseForge.
  Future<int> _resolveCfProjectId(
      String baseUrl, Map<String, String> headers) async {
    if (kCurseForgeProjectId > 0) {
      await LoggerService.instance
          .info('CurseForge: usando project ID direto $kCurseForgeProjectId');
      return kCurseForgeProjectId;
    }

    final searchUrl = Uri.parse(
        '$baseUrl/mods/search?gameId=$_minecraftGameId&slug=$kCurseForgeSlug&classId=4471');
    final searchResp =
        await http.get(searchUrl, headers: headers).timeout(_httpTimeout);

    if (searchResp.statusCode != 200) {
      throw Exception('CurseForge search HTTP ${searchResp.statusCode}');
    }

    final searchData =
        jsonDecode(searchResp.body) as Map<String, dynamic>;
    final results = searchData['data'] as List;
    if (results.isEmpty) {
      throw Exception(
          'Modpack "$kCurseForgeSlug" não encontrado no CurseForge.');
    }

    final modId = results.first['id'] as int;
    await LoggerService.instance.info(
        'CurseForge: encontrado project ID $modId para slug "$kCurseForgeSlug"');
    return modId;
  }

  /// Busca metadata do último arquivo do modpack (leve — não baixa o ZIP).
  Future<Map<String, dynamic>> _fetchCfLatestFile(
      int modId, String baseUrl, Map<String, String> headers) async {
    final filesUrl = Uri.parse(
        '$baseUrl/mods/$modId/files?gameVersion=$kMinecraftVersion&sortOrder=desc');
    final filesResp =
        await http.get(filesUrl, headers: headers).timeout(_httpTimeout);

    if (filesResp.statusCode != 200) {
      throw Exception('CurseForge files HTTP ${filesResp.statusCode}');
    }

    final filesData =
        jsonDecode(filesResp.body) as Map<String, dynamic>;
    final files = filesData['data'] as List;
    if (files.isEmpty) {
      throw Exception(
          'Nenhum arquivo encontrado para MC $kMinecraftVersion no CurseForge.');
    }

    return files.first as Map<String, dynamic>;
  }

  /// Converte um arquivo de modpack CurseForge em ModpackVersion.
  /// Modpacks CurseForge contêm um manifest.json dentro de um ZIP.
  /// O manifest lista projectID + fileID de cada mod.
  Future<ModpackVersion> _parseCurseForgeFile(
    Map<String, dynamic> fileJson,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    final fileId = fileJson['id'] as int;
    final displayName = fileJson['displayName'] as String? ?? 'Unknown';

    // Resolve a URL de download — tenta downloadUrl da API, senão monta via CDN
    final downloadUrl = fileJson['downloadUrl'] as String? ??
        _buildCdnUrl(fileId, fileJson['fileName'] as String? ?? '');

    // Verifica se o modpack tem manifest.json (padrão CurseForge)
    final modules = fileJson['modules'] as List? ?? [];
    final hasManifest = modules.any(
        (m) => (m as Map<String, dynamic>)['name'] == 'manifest.json');

    if (hasManifest && downloadUrl.isNotEmpty) {
      return _fetchCurseForgeManifest(
          downloadUrl, displayName, fileId, baseUrl, headers);
    }

    // Fallback: mods como dependências diretas
    final dependencies = fileJson['dependencies'] as List? ?? [];
    final modFiles = <ModFile>[];

    for (final dep in dependencies) {
      final depMap = dep as Map<String, dynamic>;
      final depModId = depMap['modId'] as int;
      try {
        final mod = await _fetchCurseForgeMod(depModId, baseUrl, headers);
        if (mod != null) modFiles.add(mod);
      } catch (_) {}
    }

    return ModpackVersion(
      id: fileId.toString(),
      versionNumber: displayName,
      name: displayName,
      files: modFiles,
    );
  }

  /// Baixa o ZIP do modpack, extrai manifest.json e overrides, resolve cada mod.
  /// Download é streaming para disco (evita ~500MB na RAM).
  Future<ModpackVersion> _fetchCurseForgeManifest(
    String zipUrl,
    String versionName,
    int fileId,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    await LoggerService.instance
        .info('Baixando modpack ZIP: $zipUrl (pode demorar ~500MB)...');

    // Stream download para arquivo temporário (evita ~500MB na RAM)
    final base = await getApplicationSupportDirectory();
    final tempZip = File('${base.path}/modpack_temp.zip');

    final request = http.Request('GET', Uri.parse(zipUrl));
    request.headers['User-Agent'] = _userAgent;
    final streamed =
        await request.send().timeout(const Duration(seconds: 300));

    if (streamed.statusCode != 200) {
      throw Exception('CurseForge download HTTP ${streamed.statusCode}');
    }

    final fileSink = tempZip.openWrite();
    await streamed.stream.pipe(fileSink);
    await fileSink.close();

    final zipSize = await tempZip.length();
    await LoggerService.instance
        .info('ZIP baixado ($zipSize bytes). Extraindo manifest...');

    // Decodifica ZIP do disco — single-pass para manifest + overrides
    final inputStream = InputFileStream(tempZip.path);
    final archive = ZipDecoder().decodeBuffer(inputStream);

    String? manifestContent;
    final gameDir = Directory('${base.path}/minecraft');
    if (!await gameDir.exists()) await gameDir.create(recursive: true);
    int overridesCount = 0;

    for (final file in archive) {
      if (!file.isFile) continue;

      // Extrai manifest.json
      if (manifestContent == null && file.name.endsWith('manifest.json')) {
        manifestContent = utf8.decode(file.content as List<int>);
        continue;
      }

      // Extrai overrides/ e client-overrides/
      String? relativePath;
      if (file.name.startsWith('overrides/')) {
        relativePath = file.name.substring('overrides/'.length);
      } else if (file.name.startsWith('client-overrides/')) {
        relativePath = file.name.substring('client-overrides/'.length);
      }
      if (relativePath == null || relativePath.isEmpty) continue;
      if (relativePath.startsWith('mods/')) continue;

      final outFile = File('${gameDir.path}/$relativePath');
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
      overridesCount++;
    }

    inputStream.close();
    try { await tempZip.delete(); } catch (_) {}

    if (manifestContent == null) {
      throw Exception('manifest.json não encontrado no ZIP do CurseForge.');
    }

    if (overridesCount > 0) {
      await LoggerService.instance
          .info('Overrides extraídos: $overridesCount arquivo(s) (configs, resourcepacks, etc.)');
    }

    final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
    final cfFiles = manifest['files'] as List? ?? [];
    final versionNumber = manifest['version'] as String? ?? versionName;

    await LoggerService.instance
        .info('Manifest encontrado: v$versionNumber, ${cfFiles.length} mods');

    // Resolve cada mod (projectID + fileID) em paralelo por lotes
    final modFiles = <ModFile>[];
    for (int i = 0; i < cfFiles.length; i += _batchSize) {
      final batch = cfFiles.sublist(
          i, (i + _batchSize).clamp(0, cfFiles.length));
      final results = await Future.wait(batch.map((cfFile) async {
        final projId = cfFile['projectID'] as int;
        final cfFileId = cfFile['fileID'] as int;
        try {
          return await _fetchCurseForgeFileById(
              projId, cfFileId, baseUrl, headers);
        } catch (e) {
          await LoggerService.instance
              .warn('Falha ao resolver mod $projId/$cfFileId: $e');
          return null;
        }
      }));
      modFiles.addAll(results.whereType<ModFile>());
    }

    await LoggerService.instance
        .info('Resolvidos ${modFiles.length}/${cfFiles.length} mods do manifest');

    return ModpackVersion(
      id: fileId.toString(),
      versionNumber: versionNumber,
      name: versionName,
      files: modFiles,
    );
  }

  /// Busca info de um mod específico no CurseForge (último file compatível).
  Future<ModFile?> _fetchCurseForgeMod(
      int modId, String baseUrl, Map<String, String> headers) async {
    final url = Uri.parse(
        '$baseUrl/mods/$modId/files?gameVersion=$kMinecraftVersion&sortOrder=desc&pageSize=1');
    final resp =
        await http.get(url, headers: headers).timeout(_httpTimeout);

    if (resp.statusCode != 200) return null;

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final files = data['data'] as List;
    if (files.isEmpty) return null;

    return _cfFileToModFile(files.first as Map<String, dynamic>);
  }

  /// Busca um arquivo específico por projectID + fileID.
  Future<ModFile?> _fetchCurseForgeFileById(
      int projectId, int fileId, String baseUrl, Map<String, String> headers) async {
    final url = Uri.parse('$baseUrl/mods/$projectId/files/$fileId');
    final resp =
        await http.get(url, headers: headers).timeout(_httpTimeout);

    if (resp.statusCode != 200) return null;

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final file = data['data'] as Map<String, dynamic>;
    return _cfFileToModFile(file);
  }

  /// Converte file JSON do CurseForge em ModFile.
  ModFile? _cfFileToModFile(Map<String, dynamic> file) {
    final fileId = file['id'] as int;
    final fileName = file['fileName'] as String;

    // Resolve URL: tenta downloadUrl da API, senão monta via CDN
    String? downloadUrl = file['downloadUrl'] as String?;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      downloadUrl = _buildCdnUrl(fileId, fileName);
    }

    // Troca edge.forgecdn.net por mediafilez.forgecdn.net (mais confiável)
    downloadUrl = downloadUrl.replaceFirst(
        'edge.forgecdn.net', 'mediafilez.forgecdn.net');

    final hashes = file['hashes'] as List? ?? [];
    String sha1Hash = '';
    for (final h in hashes) {
      final hashMap = h as Map<String, dynamic>;
      if (hashMap['algo'] == 1) {
        sha1Hash = hashMap['value'] as String;
        break;
      }
    }

    final fileLength = file['fileLength'] as int? ?? 0;

    return ModFile(
      name: fileName,
      downloadUrl: downloadUrl,
      sha1: sha1Hash,
      size: fileLength,
    );
  }

  /// Constrói a URL do CDN a partir do file ID.
  /// Formato: https://mediafilez.forgecdn.net/files/{id/1000}/{id%1000}/{filename}
  String _buildCdnUrl(int fileId, String fileName) {
    final p1 = fileId ~/ 1000;
    final p2 = fileId % 1000;
    return '$_forgeCdn/files/$p1/$p2/$fileName';
  }

  /// Headers para a API oficial do CurseForge (requer API key).
  Map<String, String> _cfOfficialHeaders() => {
        'x-api-key': kCurseForgeApiKey,
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      };

  /// Headers para a API pública curse.tools (não requer API key).
  Map<String, String> _cfPublicHeaders() => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      };

  // ═══════════════════════════════════════════════════════════════════════════
  //  CORE — compartilhado entre Modrinth e CurseForge
  // ═══════════════════════════════════════════════════════════════════════════

  /// Aplica um ModpackVersion (de qualquer source) — faz delta update.
  Future<UpdateResult> _applyUpdate(
    ModpackVersion latestVersion, {
    void Function(int, int, String)? onProgress,
    void Function(String)? onStatus,
  }) async {
    final modsDir = await _getModsDir();
    final toDownload = <ModFile>[];
    final toDelete = <File>[];

    // Quais mods precisam ser baixados
    for (final mod in latestVersion.files) {
      final file = File('${modsDir.path}/${mod.name}');
      if (!await file.exists() ||
          (mod.sha1.isNotEmpty && !await _validateHash(file, mod.sha1))) {
        toDownload.add(mod);
      }
    }

    // Quais mods locais não estão mais na versão atual
    final expectedNames = latestVersion.files.map((m) => m.name).toSet();
    await for (final entity in modsDir.list()) {
      if (entity is File && entity.path.endsWith('.jar')) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!expectedNames.contains(name)) {
          toDelete.add(entity);
        }
      }
    }

    for (final file in toDelete) {
      await file.delete();
      await LoggerService.instance.info('Removido mod obsoleto: ${file.path}');
    }

    if (toDownload.isEmpty) {
      await _saveCurrentVersion(latestVersion.versionNumber);
      return UpdateResult(
        updated: false,
        modsDownloaded: 0,
        versionNumber: latestVersion.versionNumber,
      );
    }

    await LoggerService.instance
        .info('${toDownload.length} mod(s) para baixar, ${toDelete.length} removido(s)');

    // Baixa mods em lotes paralelos
    int done = 0;
    for (int i = 0; i < toDownload.length; i += _batchSize) {
      final batch = toDownload.sublist(
        i,
        (i + _batchSize).clamp(0, toDownload.length),
      );

      await Future.wait(batch.map((mod) async {
        onProgress?.call(done, toDownload.length, mod.name);
        await _downloadWithRetry(mod, modsDir);
        done++;
        onProgress?.call(done, toDownload.length, mod.name);
      }));
    }
    onProgress?.call(toDownload.length, toDownload.length, '');

    await _saveCurrentVersion(latestVersion.versionNumber);
    await LoggerService.instance.info(
        'Sync concluído: ${toDownload.length} mod(s), versão ${latestVersion.versionNumber}');

    return UpdateResult(
      updated: true,
      modsDownloaded: toDownload.length,
      versionNumber: latestVersion.versionNumber,
    );
  }

  bool _isNetworkError(Object e) {
    final msg = e.toString();
    return e is SocketException ||
        msg.contains('SocketException') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable') ||
        msg.contains('Connection reset') ||
        msg.contains('Connection closed');
  }

  Future<Directory> _getModsDir() async {
    final base = await getApplicationSupportDirectory();
    final modsDir = Directory('${base.path}/minecraft/mods');
    if (!await modsDir.exists()) await modsDir.create(recursive: true);
    return modsDir;
  }

  Future<bool> _validateHash(File file, String expectedSha1) async {
    final digestSink = _DigestSink();
    final hashInput = sha1.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      hashInput.add(chunk);
    }
    hashInput.close();
    return digestSink.value?.toString() == expectedSha1;
  }

  Future<void> _downloadWithRetry(ModFile mod, Directory modsDir) async {
    const maxAttempts = 3;
    Exception? lastError;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _downloadMod(mod, modsDir);
        return;
      } on Exception catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    }

    throw lastError!;
  }

  Future<void> _downloadMod(ModFile mod, Directory modsDir) async {
    final request = http.Request('GET', Uri.parse(mod.downloadUrl));
    request.headers['User-Agent'] = _userAgent;
    final response = await request.send().timeout(_downloadTimeout);

    if (response.statusCode != 200) {
      final msg = 'Erro ao baixar ${mod.name}: HTTP ${response.statusCode}';
      await LoggerService.instance.error(msg);
      throw Exception(msg);
    }

    final file = File('${modsDir.path}/${mod.name}');
    final fileSink = file.openWrite();

    if (mod.sha1.isNotEmpty) {
      // Stream para disco + hash simultâneo (evita buffering na RAM)
      final digestSink = _DigestSink();
      final hashInput = sha1.startChunkedConversion(digestSink);
      await for (final chunk in response.stream) {
        fileSink.add(chunk);
        hashInput.add(chunk);
      }
      await fileSink.close();
      hashInput.close();

      final computedHash = digestSink.value?.toString() ?? '';
      if (computedHash.isEmpty || computedHash != mod.sha1) {
        await file.delete();
        final msg = 'Hash inválido para ${mod.name}. Download corrompido.';
        await LoggerService.instance.error(msg);
        throw Exception(msg);
      }
    } else {
      await response.stream.pipe(fileSink);
      await fileSink.close();
    }
  }

  Future<void> _saveCurrentVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefKey.modpackVersion.key, version);
  }
}

class UpdateResult {
  final bool updated;
  final int modsDownloaded;
  final String versionNumber;

  const UpdateResult({
    required this.updated,
    required this.modsDownloaded,
    required this.versionNumber,
  });
}

/// Sink auxiliar para capturar Digest de hash incremental.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
