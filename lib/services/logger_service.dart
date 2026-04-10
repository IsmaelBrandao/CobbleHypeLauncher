import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Serviço singleton de logging para o launcher.
/// Grava logs em arquivo com rotação automática (5MB → .log.old).
/// Crash reports salvos em pasta separada com timestamp.
/// Android não usa armazenamento de arquivo de log — silently ignora.
class LoggerService {
  static LoggerService? _instance;
  static LoggerService get instance => _instance ??= LoggerService._();
  LoggerService._();

  File? _logFile;
  Directory? _crashDir;

  // Buffer de escrita — flush a cada 250ms (evita open/write/close por linha)
  final List<String> _writeBuffer = [];
  Timer? _flushTimer;

  /// Inicializa o serviço: localiza o arquivo de log e realiza rotação se necessário.
  /// Deve ser chamado em main() antes de runApp().
  Future<void> init() async {
    // Android não tem getApplicationSupportDirectory confiável para escrita de log
    if (Platform.isAndroid) return;

    try {
      final dir = await getApplicationSupportDirectory();
      _logFile = File('${dir.path}/launcher.log');

      // Cria diretório de crash reports
      _crashDir = Directory('${dir.path}/crash_reports');
      if (!await _crashDir!.exists()) {
        await _crashDir!.create(recursive: true);
      }

      // Limpa crash reports antigos (>30 dias, máximo 50 arquivos)
      await _cleanOldCrashReports();

      // Rotaciona se o log ultrapassar 5MB
      if (await _logFile!.exists() &&
          await _logFile!.length() > 5 * 1024 * 1024) {
        final old = File('${dir.path}/launcher.log.old');
        if (await old.exists()) await old.delete();
        await _logFile!.rename(old.path);
        _logFile = File('${dir.path}/launcher.log');
      }
    } catch (_) {
      // Falha silenciosa: logging não deve impedir o launcher de abrir
      _logFile = null;
    }
  }

  /// Grava uma linha de log com timestamp ISO-8601 e nível.
  /// Usa buffer + flush periódico (250ms) para evitar open/write/close por linha.
  /// Minecraft pode emitir 50-200 linhas/s no startup — sem batching isso causa I/O storm.
  Future<void> log(String level, String message) async {
    if (_logFile == null) return;
    try {
      final timestamp = DateTime.now().toIso8601String();
      final line = '[$timestamp] [$level] $message\n';
      _writeBuffer.add(line);
      _flushTimer ??= Timer(const Duration(milliseconds: 250), _flushBuffer);
    } catch (_) {}
  }

  Future<void> _flushBuffer() async {
    _flushTimer = null;
    if (_writeBuffer.isEmpty || _logFile == null) return;
    final batch = _writeBuffer.join();
    _writeBuffer.clear();
    try {
      await _logFile!.writeAsString(batch, mode: FileMode.append);
    } catch (_) {}
  }

  /// Flush imediato — chamar antes de sair do app ou em crash reports.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flushBuffer();
  }

  Future<void> info(String message) => log('INFO', message);
  Future<void> warn(String message) => log('WARN', message);
  Future<void> error(String message) => log('ERROR', message);

  /// Salva um crash report completo do LAUNCHER (erro não capturado do Flutter).
  /// Retorna o caminho do arquivo salvo, ou null se falhar.
  Future<String?> saveLauncherCrashReport(
      Object error, StackTrace? stackTrace) async {
    await flush(); // Garante que logs pendentes sejam escritos antes do crash report
    if (_crashDir == null) return null;
    try {
      final now = DateTime.now();
      final timestamp = now.toIso8601String().replaceAll(':', '-');
      final file = File('${_crashDir!.path}/launcher_crash_$timestamp.txt');

      final buffer = StringBuffer()
        ..writeln('═══════════════════════════════════════════')
        ..writeln('  COBBLEHYPE LAUNCHER — CRASH REPORT')
        ..writeln('═══════════════════════════════════════════')
        ..writeln()
        ..writeln('Timestamp: ${now.toIso8601String()}')
        ..writeln('Platform:  ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Dart:      ${Platform.version}')
        ..writeln()
        ..writeln('── ERROR ──────────────────────────────────')
        ..writeln(error.toString())
        ..writeln()
        ..writeln('── STACK TRACE ────────────────────────────')
        ..writeln(stackTrace?.toString() ?? 'Não disponível')
        ..writeln()
        ..writeln('── ÚLTIMAS LINHAS DO LOG ──────────────────')
        ..writeln(await readLastLines(50));

      await file.writeAsString(buffer.toString());
      await log('CRASH', 'Crash report salvo: ${file.path}');
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Salva um crash report do JOGO (Minecraft fechou com erro).
  /// Retorna o caminho do arquivo salvo, ou null se falhar.
  Future<String?> saveGameCrashReport(int exitCode, String gameLog) async {
    if (_crashDir == null) return null;
    try {
      final now = DateTime.now();
      final timestamp = now.toIso8601String().replaceAll(':', '-');
      final file = File('${_crashDir!.path}/game_crash_$timestamp.txt');

      final buffer = StringBuffer()
        ..writeln('═══════════════════════════════════════════')
        ..writeln('  MINECRAFT — CRASH REPORT')
        ..writeln('═══════════════════════════════════════════')
        ..writeln()
        ..writeln('Timestamp:  ${now.toIso8601String()}')
        ..writeln('Exit Code:  $exitCode')
        ..writeln('Platform:   ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln()
        ..writeln('── GAME LOG (últimas linhas) ──────────────')
        ..writeln(gameLog)
        ..writeln()
        ..writeln('── LAUNCHER LOG ───────────────────────────')
        ..writeln(await readLastLines(30));

      await file.writeAsString(buffer.toString());
      await log('GAME_CRASH', 'Game crash report salvo: ${file.path}');
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Retorna o caminho absoluto do arquivo de log atual.
  Future<String> getLogPath() async {
    return _logFile?.path ?? 'N/A';
  }

  /// Retorna o caminho do diretório de crash reports.
  String? get crashDirPath => _crashDir?.path;

  /// Retorna as últimas [count] linhas do log como string.
  Future<String> readLastLines(int count) async {
    if (_logFile == null || !await _logFile!.exists()) return '';
    try {
      final lines = await _logFile!.readAsLines();
      final start = lines.length > count ? lines.length - count : 0;
      return lines.sublist(start).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Remove crash reports com mais de 30 dias e mantém no máximo 50.
  Future<void> _cleanOldCrashReports() async {
    if (_crashDir == null) return;
    try {
      final files = await _crashDir!
          .list()
          .where((e) => e is File && e.path.endsWith('.txt'))
          .cast<File>()
          .toList();

      // Remove os com mais de 30 dias
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      for (final file in files) {
        final stat = await file.stat();
        if (stat.modified.isBefore(cutoff)) {
          await file.delete();
        }
      }

      // Se ainda tem mais de 50, remove os mais antigos
      final remaining = await _crashDir!
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      if (remaining.length > 50) {
        remaining.sort((a, b) =>
            a.statSync().modified.compareTo(b.statSync().modified));
        for (var i = 0; i < remaining.length - 50; i++) {
          await remaining[i].delete();
        }
      }
    } catch (_) {}
  }
}
