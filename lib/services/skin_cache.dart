import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Cache local de imagens de skin (head e body) para evitar
/// re-downloads desnecessários do mc-heads.net.
///
/// Armazena em {appSupport}/skin_cache/ com TTL de 1 hora.
/// Após o TTL, re-baixa em background (serve stale enquanto atualiza).
class SkinCache {
  static const Duration _cacheTtl = Duration(hours: 1);
  static const Duration _downloadTimeout = Duration(seconds: 10);

  static SkinCache? _instance;
  Directory? _cacheDir;
  final Map<String, String> _filenameCache = {};

  /// Rastreia requisições em andamento para evitar downloads duplicados
  /// quando múltiplos widgets solicitam a mesma URL simultaneamente.
  static final Map<String, Future<Uint8List?>> _inflightRequests = {};

  SkinCache._();

  /// Singleton para evitar múltiplas instâncias
  static SkinCache get instance {
    _instance ??= SkinCache._();
    return _instance!;
  }

  Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    _cacheDir = Directory('${base.path}/skin_cache');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    return _cacheDir!;
  }

  /// Gera um nome de arquivo determinístico a partir da URL usando MD5.
  /// Garante nomes estáveis entre execuções (url.hashCode não é estável).
  String _urlToFileName(String url) {
    return _filenameCache.putIfAbsent(url, () {
      final bytes = utf8.encode(url);
      final digest = md5.convert(bytes);
      return 'skin_$digest.png';
    });
  }

  /// Retorna o caminho do arquivo em cache, ou null se não existe/expirou.
  Future<String?> getCachedPath(String url) async {
    final dir = await _getCacheDir();
    final file = File('${dir.path}/${_urlToFileName(url)}');

    if (!await file.exists()) return null;

    final stat = await file.stat();
    final age = DateTime.now().difference(stat.modified);

    if (age > _cacheTtl) {
      // Cache expirado — serve stale mas inicia re-download em background
      _refreshInBackground(url, file);
    }

    return file.path;
  }

  /// Baixa a imagem e salva no cache. Retorna o caminho local.
  Future<String?> downloadAndCache(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(_downloadTimeout);

      if (response.statusCode != 200) return null;

      final dir = await _getCacheDir();
      final file = File('${dir.path}/${_urlToFileName(url)}');
      await file.writeAsBytes(response.bodyBytes);

      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Retorna bytes da skin — primeiro do cache, depois da rede.
  ///
  /// Deduplicação: se duas chamadas concorrentes chegarem para a mesma URL,
  /// apenas um download HTTP é iniciado — a segunda chamada aguarda o mesmo Future.
  Future<Uint8List?> getSkinBytes(String url) async {
    // 1. Tenta cache local (sem necessidade de dedup — só leitura de disco)
    final cached = await getCachedPath(url);
    if (cached != null) {
      try {
        return await File(cached).readAsBytes();
      } catch (_) {
        // Arquivo corrompido — ignora e baixa novamente
      }
    }

    // 2. Deduplicação: reutiliza o Future em andamento para a mesma URL
    if (_inflightRequests.containsKey(url)) {
      return _inflightRequests[url];
    }

    final future = _fetchAndReadBytes(url);
    _inflightRequests[url] = future;

    try {
      return await future;
    } finally {
      _inflightRequests.remove(url);
    }
  }

  /// Baixa a skin, salva no cache e retorna os bytes.
  /// Separado de getSkinBytes para ser o alvo da deduplicação.
  Future<Uint8List?> _fetchAndReadBytes(String url) async {
    final path = await downloadAndCache(url);
    if (path == null) return null;

    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Re-download silencioso em background (serve stale first)
  void _refreshInBackground(String url, File existingFile) {
    // Fire-and-forget
    Future(() async {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(_downloadTimeout);
        if (response.statusCode == 200) {
          await existingFile.writeAsBytes(response.bodyBytes);
        }
      } catch (_) {
        // Silencioso — a versão stale continua servindo
      }
    });
  }

  /// Limpa todo o cache de skins
  Future<void> clearCache() async {
    final dir = await _getCacheDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }
}
