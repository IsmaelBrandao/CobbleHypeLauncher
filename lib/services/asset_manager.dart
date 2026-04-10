import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pref_keys.dart';

/// Gerencia download e validacao de assets vanilla.
class AssetManager {
  static const String _versionManifestUrl =
      'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
  static const String _assetsBaseUrl =
      'https://resources.download.minecraft.net';
  static const int _batchSize = 10;
  static const int _spotCheckCount = 5;
  static const Duration _apiTimeout = Duration(seconds: 30);
  static const Duration _assetDownloadTimeout = Duration(seconds: 60);

  static Map<String, dynamic>? _cachedVersionManifest;
  static final Map<String, Map<String, dynamic>> _versionMetaCache = {};
  static final Map<String, _CachedAssetIndex> _assetIndexCache = {};

  /// Garante que os assets do [mcVersion] existem em [gameDir].
  Future<void> ensureAssets({
    required String gameDir,
    String mcVersion = '1.21.1',
    void Function(int done, int total, String asset)? onProgress,
    void Function(String message)? onLog,
  }) async {
    onLog?.call('Verificando assets do Minecraft...');

    await _checkConnectivity();

    final versionMeta = await _fetchVersionMeta(mcVersion);
    final assetIndexInfo = versionMeta['assetIndex'] as Map<String, dynamic>;
    final assetIndexId = assetIndexInfo['id'] as String;
    final assetIndexUrl = assetIndexInfo['url'] as String;
    final assetIndexSha1 = assetIndexInfo['sha1'] as String;

    final indexFile = File('$gameDir/assets/indexes/$assetIndexId.json');
    final indexJson = await _ensureAssetIndex(
      indexFile: indexFile,
      assetIndexUrl: assetIndexUrl,
      assetIndexSha1: assetIndexSha1,
      onLog: onLog,
    );

    final objects = indexJson['objects'] as Map<String, dynamic>;
    final entries = objects.entries.toList();
    final total = entries.length;
    var done = 0;

    onLog?.call('Assets a verificar/baixar: $total');

    for (var i = 0; i < entries.length; i += _batchSize) {
      final batch = entries.sublist(
        i,
        (i + _batchSize).clamp(0, entries.length),
      );

      await Future.wait(batch.map((entry) async {
        final assetName = entry.key;
        final meta = entry.value as Map<String, dynamic>;
        final hash = meta['hash'] as String;
        final size = meta['size'] as int;

        try {
          await _ensureObject(
            gameDir: gameDir,
            hash: hash,
            size: size,
          );
        } catch (e) {
          onLog?.call('Aviso: falha ao baixar asset $assetName: $e');
        }

        done++;
        onProgress?.call(done, total, assetName);
      }));
    }

    onLog?.call('Assets verificados/baixados: $done/$total');
  }

  /// Retorna true quando os assets parecem completos.
  Future<bool> isComplete(String gameDir, {String mcVersion = '1.21.1'}) async {
    try {
      final indexesDir = Directory('$gameDir/assets/indexes');
      if (!await indexesDir.exists()) return false;

      final indexFiles = await indexesDir
          .list()
          .where((e) => e.path.endsWith('.json'))
          .toList();
      if (indexFiles.isEmpty) return false;

      final indexJson = await _readCachedAssetIndex(File(indexFiles.first.path));
      final objects = indexJson['objects'] as Map<String, dynamic>;
      if (objects.isEmpty) return false;

      final sample = objects.entries.take(_spotCheckCount).toList();
      for (final entry in sample) {
        final meta = entry.value as Map<String, dynamic>;
        final hash = meta['hash'] as String;
        final objFile =
            File('$gameDir/assets/objects/${hash.substring(0, 2)}/$hash');
        if (!await objFile.exists()) return false;
        if (await objFile.length() != (meta['size'] as int)) return false;
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Retorna o caminho do client.jar vanilla se existir.
  Future<String?> getClientJarPath(String gameDir) async {
    try {
      final versionMeta = await _fetchVersionMeta('1.21.1');
      final downloads = versionMeta['downloads'] as Map<String, dynamic>?;
      if (downloads == null) return null;

      final clientJar = File('$gameDir/versions/1.21.1/1.21.1.jar');
      if (await clientJar.exists()) return clientJar.path;

      final clientInfo = downloads['client'] as Map<String, dynamic>?;
      if (clientInfo == null) return null;

      await _downloadClientJar(
        gameDir: gameDir,
        url: clientInfo['url'] as String,
        sha1Hash: clientInfo['sha1'] as String,
      );
      return await clientJar.exists() ? clientJar.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkConnectivity() async {
    try {
      await http.head(Uri.parse(_versionManifestUrl)).timeout(_apiTimeout);
    } catch (_) {
      throw Exception('Sem conexao com a internet. Verifique sua rede.');
    }
  }

  Future<Map<String, dynamic>> _fetchVersionMeta(String mcVersion) async {
    final cached = _versionMetaCache[mcVersion];
    if (cached != null) return cached;

    final manifest = await _fetchVersionManifest();
    final versions = manifest['versions'] as List;

    final entry = versions.cast<Map<String, dynamic>>().firstWhere(
          (v) => v['id'] == mcVersion,
          orElse: () => throw Exception(
              'Versao $mcVersion nao encontrada no manifesto Mojang'),
        );

    final versionUrl = entry['url'] as String;
    final versionResp =
        await http.get(Uri.parse(versionUrl)).timeout(_apiTimeout);
    if (versionResp.statusCode != 200) {
      throw Exception(
          'Falha ao baixar version JSON de $mcVersion: ${versionResp.statusCode}');
    }

    final versionMeta = jsonDecode(versionResp.body) as Map<String, dynamic>;
    _versionMetaCache[mcVersion] = versionMeta;
    return versionMeta;
  }

  Future<Map<String, dynamic>> _fetchVersionManifest() async {
    if (_cachedVersionManifest != null) return _cachedVersionManifest!;

    final manifestResp =
        await http.get(Uri.parse(_versionManifestUrl)).timeout(_apiTimeout);
    if (manifestResp.statusCode != 200) {
      throw Exception(
          'Falha ao baixar manifesto de versoes: ${manifestResp.statusCode}');
    }

    final manifest = jsonDecode(manifestResp.body) as Map<String, dynamic>;
    _cachedVersionManifest = manifest;
    return manifest;
  }

  Future<Map<String, dynamic>> _ensureAssetIndex({
    required File indexFile,
    required String assetIndexUrl,
    required String assetIndexSha1,
    void Function(String)? onLog,
  }) async {
    if (await indexFile.exists()) {
      final existing = await indexFile.readAsBytes();
      final actualSha1 = sha1.convert(existing).toString();
      if (actualSha1 == assetIndexSha1) {
        return _readCachedAssetIndex(indexFile, existingBytes: existing);
      }
      onLog?.call('Asset index corrompido, re-baixando...');
    }

    await indexFile.parent.create(recursive: true);

    onLog?.call('Baixando asset index...');
    final resp =
        await http.get(Uri.parse(assetIndexUrl)).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Falha ao baixar asset index: ${resp.statusCode}');
    }

    final actualSha1 = sha1.convert(resp.bodyBytes).toString();
    if (actualSha1 != assetIndexSha1) {
      throw Exception(
          'Checksum invalido do asset index: esperado $assetIndexSha1, obtido $actualSha1');
    }

    await indexFile.writeAsBytes(resp.bodyBytes);
    return _readCachedAssetIndex(indexFile, existingBytes: resp.bodyBytes);
  }

  Future<Map<String, dynamic>> _readCachedAssetIndex(
    File indexFile, {
    List<int>? existingBytes,
  }) async {
    final stat = await indexFile.stat();
    final cached = _assetIndexCache[indexFile.path];
    if (cached != null && cached.modified == stat.modified) {
      return cached.json;
    }

    final jsonText = existingBytes != null
        ? utf8.decode(existingBytes)
        : await indexFile.readAsString();
    final json = jsonDecode(jsonText) as Map<String, dynamic>;
    _assetIndexCache[indexFile.path] = _CachedAssetIndex(
      modified: stat.modified,
      json: json,
    );
    return json;
  }

  Future<void> _ensureObject({
    required String gameDir,
    required String hash,
    required int size,
  }) async {
    final prefix = hash.substring(0, 2);
    final objFile = File('$gameDir/assets/objects/$prefix/$hash');

    if (await objFile.exists() && await objFile.length() == size) {
      return;
    }

    await objFile.parent.create(recursive: true);

    final url = '$_assetsBaseUrl/$prefix/$hash';
    final resp = await http.get(Uri.parse(url)).timeout(_assetDownloadTimeout);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode} para $url');
    }

    if (resp.bodyBytes.length != size) {
      throw Exception(
          'Tamanho incorreto para $hash: esperado $size, obtido ${resp.bodyBytes.length}');
    }

    await objFile.writeAsBytes(resp.bodyBytes);
  }

  Future<void> _downloadClientJar({
    required String gameDir,
    required String url,
    required String sha1Hash,
  }) async {
    final jarFile = File('$gameDir/versions/1.21.1/1.21.1.jar');
    await jarFile.parent.create(recursive: true);

    final request = http.Request('GET', Uri.parse(url));
    final response = await request.send().timeout(_assetDownloadTimeout);
    if (response.statusCode != 200) {
      throw Exception('Falha ao baixar client.jar: ${response.statusCode}');
    }

    final fileSink = jarFile.openWrite();
    final digestSink = _DigestSink();
    final hashInput = sha1.startChunkedConversion(digestSink);

    try {
      await for (final chunk in response.stream) {
        fileSink.add(chunk);
        hashInput.add(chunk);
      }
    } finally {
      await fileSink.close();
      hashInput.close();
    }

    final actualSha1 = digestSink.value?.toString() ?? '';
    if (actualSha1 != sha1Hash) {
      await jarFile.delete();
      throw Exception(
          'Checksum invalido do client.jar: esperado $sha1Hash, obtido $actualSha1');
    }
  }

  /// Resolve o gameDir usando SharedPreferences ou fallback padrao.
  static Future<String> resolveGameDir() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString(PrefKey.gameDirectory.key);
    if (custom != null && custom.isNotEmpty) return custom;

    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/minecraft');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }
}

class _CachedAssetIndex {
  final DateTime modified;
  final Map<String, dynamic> json;

  const _CachedAssetIndex({
    required this.modified,
    required this.json,
  });
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
