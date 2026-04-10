import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart';
import 'pref_keys.dart';

/// Gerencia o download e instalação do JRE 21 via Adoptium API.
///
/// Ordem de preferência ao resolver o caminho Java:
///   1. Caminho configurado pelo usuário em SharedPreferences (java_path_override)
///   2. JRE gerenciado pelo launcher (baixado anteriormente)
///   3. Java 21+ encontrado no sistema (JAVA_HOME, paths comuns, PATH)
///   4. Download via Adoptium (último recurso)
class JavaManager {
  static const String _adoptiumBase =
      'https://api.adoptium.net/v3/assets/latest/21/hotspot';

  /// Retorna o caminho do executável Java.
  /// Se não estiver disponível em nenhum local, faz o download primeiro.
  Future<String> getJavaPath({
    void Function(String status, double progress)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      throw UnsupportedError(
        'Android não requer download de Java — use o PojavLauncher.',
      );
    }

    final prefs = await SharedPreferences.getInstance();

    // 1. Caminho configurado manualmente pelo usuário
    final override = prefs.getString(PrefKey.javaPathOverride.key);
    if (override != null && override.isNotEmpty && await File(override).exists()) {
      await LoggerService.instance.info('Usando Java configurado pelo usuário: $override');
      return override;
    }

    // 2. JRE gerenciado pelo launcher (baixado anteriormente)
    final cached = prefs.getString(PrefKey.javaPath.key);
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    // 3. Java 21+ instalado no sistema
    onProgress?.call('Procurando Java 21 no sistema...', 0.0);
    final systemJava = await _findSystemJava();
    if (systemJava != null) {
      await LoggerService.instance.info('Java 21 encontrado no sistema: $systemJava');
      await prefs.setString(PrefKey.javaPath.key, systemJava);
      return systemJava;
    }

    // 4. Download via Adoptium
    return _downloadAndInstall(onProgress: onProgress);
  }

  /// Verifica se o JRE já está disponível (verificação rápida ~50ms).
  /// No Android sempre retorna true — o PojavLauncher gerencia o Java.
  Future<bool> isInstalled() async {
    if (Platform.isAndroid) return true;

    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(PrefKey.javaPath.key);
    return cached != null && await File(cached).exists();
  }

  // ---------------------------------------------------------------------------
  // Detecção de Java instalado no sistema
  // ---------------------------------------------------------------------------

  /// Procura por uma instalação de Java 21+ no sistema.
  /// Verifica JAVA_HOME, caminhos comuns de instalação e PATH.
  /// Retorna o caminho do executável ou null se não encontrado.
  Future<String?> _findSystemJava() async {
    final candidates = <String>[];

    if (Platform.isWindows) {
      // Verifica JAVA_HOME
      final javaHome = Platform.environment['JAVA_HOME'];
      if (javaHome != null && javaHome.isNotEmpty) {
        candidates.add('$javaHome/bin/javaw.exe');
      }

      // Caminhos comuns de instalação no Windows
      for (final base in [
        'C:/Program Files/Java',
        'C:/Program Files/Eclipse Adoptium',
        'C:/Program Files/Microsoft',
        'C:/Program Files/Eclipse Foundation',
      ]) {
        final dir = Directory(base);
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            if (entry is Directory && entry.path.contains('21')) {
              candidates.add('${entry.path}/bin/javaw.exe');
            }
          }
        }
      }

      // Verifica PATH via 'where java'
      try {
        final result = await Process.run('where', ['java']);
        if (result.exitCode == 0) {
          for (final line in (result.stdout as String).split('\n')) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty) {
              // Converte java.exe para javaw.exe no Windows
              candidates.add(trimmed.replaceAll('java.exe', 'javaw.exe'));
            }
          }
        }
      } catch (_) {}
    } else {
      // Linux / macOS
      final javaHome = Platform.environment['JAVA_HOME'];
      if (javaHome != null && javaHome.isNotEmpty) {
        candidates.add('$javaHome/bin/java');
      }

      // Caminhos comuns de instalação
      for (final path in [
        '/usr/lib/jvm',
        '/usr/local/lib/jvm',
        '/Library/Java/JavaVirtualMachines',
      ]) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            if (entry is Directory && entry.path.contains('21')) {
              if (Platform.isMacOS) {
                candidates.add('${entry.path}/Contents/Home/bin/java');
              } else {
                candidates.add('${entry.path}/bin/java');
              }
            }
          }
        }
      }

      // Verifica PATH via 'which java'
      try {
        final result = await Process.run('which', ['java']);
        if (result.exitCode == 0) {
          final path = (result.stdout as String).trim();
          if (path.isNotEmpty) candidates.add(path);
        }
      } catch (_) {}
    }

    // Valida cada candidato: verifica se existe e é Java 21+
    for (final path in candidates) {
      if (!await File(path).exists()) continue;

      try {
        // Usa o binário java (sem 'w' no Windows) para -version
        final javaExec = Platform.isWindows
            ? path.replaceAll('javaw.exe', 'java.exe')
            : path;

        final result = await Process.run(javaExec, ['-version']);
        // -version imprime em stderr na maioria das JVMs
        final output = '${result.stdout}${result.stderr}';
        final match = RegExp(r'version "(\d+)').firstMatch(output);
        if (match != null) {
          final major = int.tryParse(match.group(1)!) ?? 0;
          if (major >= 21) return path;
        }
      } catch (_) {}
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Download e instalação do JRE via Adoptium
  // ---------------------------------------------------------------------------

  Future<String> _downloadAndInstall({
    void Function(String status, double progress)? onProgress,
  }) async {
    final platform = _detectPlatform();
    onProgress?.call('Buscando JRE 21 para ${platform.os}...', 0.0);
    await LoggerService.instance.info('Iniciando download do JRE 21 para ${platform.os}/${platform.arch}');

    final release = await _fetchRelease(platform);
    onProgress?.call('Baixando Java 21 (${_formatSize(release.size)})...', 0.05);

    // Timeout total de 5 minutos para o download do JRE (~180MB)
    final archivePath = await _downloadArchive(
      release,
      platform,
      onProgress: (bytesReceived, totalBytes) {
        final ratio = totalBytes > 0 ? bytesReceived / totalBytes : 0.0;
        final statusText = 'Baixando JRE 21... '
            '${(bytesReceived / 1024 / 1024).toStringAsFixed(1)} / '
            '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
        onProgress?.call(statusText, 0.05 + ratio * 0.75);
      },
    ).timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw Exception(
          'Timeout ao baixar o JRE. Verifique sua conexão e tente novamente.'),
    );

    onProgress?.call('Extraindo Java 21...', 0.80);
    final javaPath = await _extractArchive(archivePath, platform);

    await LoggerService.instance.info('JRE 21 instalado em: $javaPath');
    onProgress?.call('Java 21 pronto!', 1.0);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PrefKey.javaPath.key, javaPath);

    return javaPath;
  }

  _PlatformInfo _detectPlatform() {
    if (Platform.isWindows) {
      final arch = _getWindowsArch();
      return _PlatformInfo(os: 'windows', arch: arch, ext: 'zip');
    } else if (Platform.isLinux) {
      final arch = _getUnixArch();
      return _PlatformInfo(os: 'linux', arch: arch, ext: 'tar.gz');
    } else if (Platform.isMacOS) {
      final arch = _getUnixArch();
      return _PlatformInfo(os: 'mac', arch: arch, ext: 'tar.gz');
    }
    throw UnsupportedError('Plataforma não suportada: ${Platform.operatingSystem}');
  }

  String _getWindowsArch() {
    final envArch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    return envArch.contains('ARM') ? 'aarch64' : 'x64';
  }

  String _getUnixArch() {
    try {
      final result = Process.runSync('uname', ['-m']);
      final machine = result.stdout.toString().trim();
      if (machine.contains('aarch64') || machine.contains('arm64')) {
        return 'aarch64';
      }
    } catch (_) {}
    return 'x64';
  }

  Future<_ReleaseInfo> _fetchRelease(_PlatformInfo platform) async {
    final url = Uri.parse(
      '$_adoptiumBase?architecture=${platform.arch}&image_type=jre'
      '&os=${platform.os}&vendor=eclipse',
    );

    final response = await http
        .get(url)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      final msg = 'Erro ao buscar JRE na Adoptium: ${response.statusCode}';
      await LoggerService.instance.error(msg);
      throw Exception(msg);
    }

    final List<dynamic> releases = jsonDecode(response.body) as List;
    if (releases.isEmpty) {
      final msg = 'Nenhuma release JRE encontrada para ${platform.os}/${platform.arch}';
      await LoggerService.instance.error(msg);
      throw Exception(msg);
    }

    final release = releases.first as Map<String, dynamic>;
    final binary = release['binary'] as Map<String, dynamic>;
    final installer = binary['installer'] ?? binary['package'];
    final package = installer as Map<String, dynamic>;

    return _ReleaseInfo(
      downloadUrl: package['link'] as String,
      checksum: package['checksum'] as String,
      size: package['size'] as int,
    );
  }

  /// Faz o download do arquivo JRE com progresso por bytes.
  /// [onProgress] recebe (bytesReceived, totalBytes).
  Future<String> _downloadArchive(
    _ReleaseInfo release,
    _PlatformInfo platform, {
    void Function(int bytesReceived, int totalBytes)? onProgress,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final archivePath = '${dir.path}/jre21_download.${platform.ext}';

    final request = http.Request('GET', Uri.parse(release.downloadUrl));
    final streamedResponse = await request.send();

    final total = streamedResponse.contentLength ?? release.size;
    int received = 0;

    // Stream direto para disco + hash incremental (evita ~360MB na RAM)
    final file = File(archivePath);
    final fileSink = file.openWrite();
    final digestSink = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digestSink);

    await for (final chunk in streamedResponse.stream) {
      fileSink.add(chunk);
      hashInput.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }

    await fileSink.close();
    hashInput.close();

    // Valida SHA-256
    final computedHash = digestSink.value.toString();
    if (computedHash != release.checksum) {
      await file.delete();
      const msg = 'Download do JRE corrompido (hash inválido). Tente novamente.';
      await LoggerService.instance.error(msg);
      throw Exception(msg);
    }

    return archivePath;
  }

  Future<String> _extractArchive(String archivePath, _PlatformInfo platform) async {
    final dir = await getApplicationSupportDirectory();
    final jreDir = Directory('${dir.path}/runtime/jre21');
    if (await jreDir.exists()) await jreDir.delete(recursive: true);
    await jreDir.create(recursive: true);

    // Extrai direto do disco em isolate separado (evita carregar ~180MB na RAM
    // E evita bloquear a UI thread durante extração de ~10-30s)
    await Isolate.run(() => extractFileToDisk(archivePath, jreDir.path));

    // Remove o arquivo baixado
    await File(archivePath).delete();

    // Encontra o binário java dentro da pasta extraída
    return _findJavaBinary(jreDir.path, platform);
  }

  String _findJavaBinary(String jrePath, _PlatformInfo platform) {
    final jreDir = Directory(jrePath);
    // A pasta extraída tem um subdiretório como "jdk-21.0.x+7-jre"
    final contents = jreDir.listSync();
    String basePath = jrePath;

    if (contents.length == 1 && contents.first is Directory) {
      basePath = contents.first.path;
    }

    if (platform.os == 'windows') {
      return '$basePath/bin/java.exe';
    } else if (platform.os == 'mac') {
      return '$basePath/Contents/Home/bin/java';
    } else {
      return '$basePath/bin/java';
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

class _PlatformInfo {
  final String os;
  final String arch;
  final String ext;
  const _PlatformInfo({required this.os, required this.arch, required this.ext});
}

class _ReleaseInfo {
  final String downloadUrl;
  final String checksum;
  final int size;
  const _ReleaseInfo({
    required this.downloadUrl,
    required this.checksum,
    required this.size,
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
