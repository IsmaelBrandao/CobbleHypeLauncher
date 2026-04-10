import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/minecraft_account.dart';

/// Gerencia o lançamento do Minecraft no Android via PojavLauncher.
///
/// Todos os métodos retornam silenciosamente se chamados fora do Android,
/// o que garante que este arquivo pode ser importado em qualquer plataforma
/// sem causar erros em tempo de compilação ou execução.
class AndroidLauncher {
  static const String _pojavPackage = 'net.kdt.pojavlaunch';

  // URL do APK do PojavLauncher (release mais recente)
  static const String _pojavDownloadUrl =
      'https://github.com/PojavLauncherTeam/PojavLauncher/releases/latest/download/app-debug.apk';

  /// Retorna true se o PojavLauncher está instalado no dispositivo.
  /// Sempre retorna false em plataformas não-Android.
  Future<bool> isPojavInstalled() async {
    if (!Platform.isAndroid) return false;
    try {
      // ignore: prefer_const_constructors
      final intent = AndroidIntent(
        action: 'android.intent.action.MAIN',
        package: _pojavPackage,
      );
      return await intent.canResolveActivity() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Abre o download do PojavLauncher APK no navegador do sistema.
  /// No-op em plataformas não-Android.
  Future<void> promptInstallPojav() async {
    if (!Platform.isAndroid) return;
    final uri = Uri.parse(_pojavDownloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Pré-configura a conta no arquivo de contas do PojavLauncher.
  ///
  /// O PojavLauncher lê accounts.json de
  ///   {externalStorage}/games/PojavLauncher/accounts.json
  ///
  /// Falha silenciosa: se não conseguir escrever, o usuário precisará logar
  /// manualmente no PojavLauncher.
  Future<void> preConfigureAccount(MinecraftAccount account) async {
    if (!Platform.isAndroid) return;
    try {
      // getExternalStorageDirectories() retorna caminhos no estilo:
      //   /storage/emulated/0/Android/data/{pkg}/files
      // A raiz do armazenamento externo está antes de "/Android".
      final dirs = await getExternalStorageDirectories();
      if (dirs == null || dirs.isEmpty) return;

      final root = dirs.first.path.split('/Android').first;
      final pojavDir = Directory('$root/games/PojavLauncher');
      if (!await pojavDir.exists()) await pojavDir.create(recursive: true);

      final accountsFile = File('${pojavDir.path}/accounts.json');

      // Formato esperado pelo PojavLauncher
      final accountsJson = {
        'currentAccount': account.username,
        'accounts': {
          account.username: {
            'accessToken': account.accessToken,
            'clientToken': account.uuid,
            'username': account.username,
            'uuid': account.uuid,
            'account_type': account.isOffline ? 'LOCAL' : 'Microsoft',
          }
        }
      };

      await accountsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(accountsJson),
      );
    } catch (_) {
      // Falha silenciosa — o jogador precisará logar manualmente no PojavLauncher
    }
  }

  /// Copia os arquivos .jar de mods de [modsSourceDir] para a pasta de mods
  /// do PojavLauncher em armazenamento externo.
  ///
  /// Falha silenciosa para não bloquear o fluxo de lançamento.
  Future<void> syncMods(String modsSourceDir) async {
    if (!Platform.isAndroid) return;
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs == null || dirs.isEmpty) return;

      final root = dirs.first.path.split('/Android').first;
      final pojavModsDir =
          Directory('$root/games/PojavLauncher/.minecraft/mods');
      if (!await pojavModsDir.exists()) {
        await pojavModsDir.create(recursive: true);
      }

      final sourceDir = Directory(modsSourceDir);
      if (!await sourceDir.exists()) return;

      await for (final entity in sourceDir.list()) {
        if (entity is File && entity.path.endsWith('.jar')) {
          final name = entity.path.split(Platform.pathSeparator).last;
          final dest = File('${pojavModsDir.path}/$name');
          await entity.copy(dest.path);
        }
      }
    } catch (_) {
      // Falha silenciosa
    }
  }

  /// Lança o PojavLauncher via Intent explícito.
  /// No-op em plataformas não-Android.
  Future<void> launch() async {
    if (!Platform.isAndroid) return;
    // ignore: prefer_const_constructors
    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: _pojavPackage,
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    await intent.launch();
  }
}
