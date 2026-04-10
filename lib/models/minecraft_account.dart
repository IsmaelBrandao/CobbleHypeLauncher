/// Conta Minecraft (Microsoft ou offline)
class MinecraftAccount {
  final String username;
  final String uuid;
  final String accessToken;
  final DateTime expiresAt;
  final bool isOffline;

  const MinecraftAccount({
    required this.username,
    required this.uuid,
    required this.accessToken,
    required this.expiresAt,
    this.isOffline = false,
  });

  bool get isExpired =>
      !isOffline && DateTime.now().isAfter(expiresAt);

  /// URL da cabeça da skin (via mc-heads.net — aceita UUID e username)
  String get skinHeadUrl {
    final id = !isOffline && uuid.isNotEmpty ? uuid : username;
    return 'https://mc-heads.net/head/$id/128';
  }

  /// URL do corpo inteiro da skin (via mc-heads.net)
  String get skinBodyUrl {
    final id = !isOffline && uuid.isNotEmpty ? uuid : username;
    return 'https://mc-heads.net/body/$id/300';
  }

  /// URL do avatar da skin (via mc-heads.net — mais confiável que Crafatar)
  String get avatarUrl {
    final id = !isOffline && uuid.isNotEmpty ? uuid : username;
    return 'https://mc-heads.net/avatar/$id/64';
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'uuid': uuid,
        'accessToken': accessToken,
        'expiresAt': expiresAt.toIso8601String(),
        'isOffline': isOffline,
      };

  factory MinecraftAccount.fromJson(Map<String, dynamic> json) {
    return MinecraftAccount(
      username: json['username'] as String,
      uuid: json['uuid'] as String,
      accessToken: json['accessToken'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      isOffline: json['isOffline'] as bool? ?? false,
    );
  }
}
