import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/modpack.dart';

class LauncherUpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;

  const LauncherUpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

/// Verifica atualizações do launcher consultando releases do GitHub.
/// Configurar [kGithubRepo] em modpack.dart para habilitar.
class LauncherUpdater {
  Future<LauncherUpdateInfo?> checkForUpdate() async {
    if (kGithubRepo.isEmpty) return null;

    try {
      final response = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/$kGithubRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final latestTag =
          (json['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (latestTag.isEmpty) return null;

      final info = await PackageInfo.fromPlatform();
      if (!_isNewer(latestTag, info.version)) return null;

      // Procura asset adequado para a plataforma atual
      final assets = json['assets'] as List? ?? [];
      String downloadUrl = json['html_url'] as String? ?? '';
      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final name = (assetMap['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.exe') ||
            name.endsWith('.appimage') ||
            name.endsWith('.dmg')) {
          downloadUrl =
              assetMap['browser_download_url'] as String? ?? downloadUrl;
          break;
        }
      }

      return LauncherUpdateInfo(
        version: latestTag,
        downloadUrl: downloadUrl,
        releaseNotes: json['body'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  bool _isNewer(String latest, String current) {
    int parse(String s) => int.tryParse(s) ?? 0;
    final l = latest.split('.').map(parse).toList();
    final c = current.split('.').map(parse).toList();

    for (var i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }
}
