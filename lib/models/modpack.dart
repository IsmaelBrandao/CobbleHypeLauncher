/// Identificadores fixos do modpack — altere aqui quando mudar de versão
const String kModpackId = 'SEU_MODPACK_ID_MODRINTH'; // ID do projeto no Modrinth
const String kFabricLoaderVersion = '0.18.6'; // Versão do Fabric Loader
const String kMinecraftVersion = '1.21.1';
const String kLauncherName = 'CobbleHype Launcher';

/// CurseForge — fonte primária de mods (o modpack está publicado lá).
/// Slug do modpack na URL: curseforge.com/minecraft/modpacks/{slug}
const String kCurseForgeSlug = 'cobblehype';

/// ID numérico do modpack no CurseForge.
/// Encontrado automaticamente: https://www.curseforge.com/minecraft/modpacks/cobblehype
const int kCurseForgeProjectId = 1489887;

/// API key do CurseForge (opcional).
/// Se vazio, o launcher usa a API pública curse.tools (sem key necessária).
/// Se preenchido, usa a API oficial do CurseForge (mais rápida e confiável).
/// Para obter: https://console.curseforge.com/ → Create API Key (grátis)
const String kCurseForgeApiKey = '';

/// Endereço do servidor Minecraft (host:porta ou só host se for porta 25565)
const String kServerAddress = 'play.cobblehype.com';

/// Repositório GitHub para auto-update do launcher (formato "owner/repo")
/// Deixe vazio para desabilitar o auto-update
const String kGithubRepo = 'IsmaelBrandao/CobbleHypeLauncher';

/// Um arquivo de mod individual
class ModFile {
  final String name;
  final String downloadUrl;
  final String sha1;
  final int size;

  const ModFile({
    required this.name,
    required this.downloadUrl,
    required this.sha1,
    required this.size,
  });

  factory ModFile.fromJson(Map<String, dynamic> json) {
    return ModFile(
      name: json['filename'] as String,
      downloadUrl: json['url'] as String,
      sha1: json['hashes']['sha1'] as String,
      size: json['size'] as int,
    );
  }
}

/// Uma versão do modpack no Modrinth
class ModpackVersion {
  final String id;
  final String versionNumber;
  final String name;
  final List<ModFile> files;

  const ModpackVersion({
    required this.id,
    required this.versionNumber,
    required this.name,
    required this.files,
  });

  /// Parse de versão vinda da API Modrinth.
  factory ModpackVersion.fromModrinthJson(Map<String, dynamic> json) {
    final filesList = (json['files'] as List)
        .map((f) => ModFile.fromJson(f as Map<String, dynamic>))
        .toList();
    return ModpackVersion(
      id: json['id'] as String,
      versionNumber: json['version_number'] as String,
      name: json['name'] as String,
      files: filesList,
    );
  }

  /// Alias para manter compatibilidade com testes existentes.
  factory ModpackVersion.fromJson(Map<String, dynamic> json) =
      ModpackVersion.fromModrinthJson;
}
