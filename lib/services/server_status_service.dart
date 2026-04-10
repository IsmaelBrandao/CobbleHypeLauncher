import 'dart:convert';
import 'package:http/http.dart' as http;

class ServerStatus {
  final bool online;
  final int playersOnline;
  final int playersMax;
  final String motd;

  const ServerStatus({
    required this.online,
    this.playersOnline = 0,
    this.playersMax = 0,
    this.motd = '',
  });

  static const ServerStatus offline = ServerStatus(online: false);
}

/// Consulta o status de um servidor Minecraft via api.mcsrvstat.us
class ServerStatusService {
  Future<ServerStatus> check(String host) async {
    if (host.isEmpty) return ServerStatus.offline;

    try {
      final response = await http
          .get(Uri.parse('https://api.mcsrvstat.us/3/$host'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return ServerStatus.offline;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final online = json['online'] as bool? ?? false;
      if (!online) return ServerStatus.offline;

      final players = json['players'] as Map<String, dynamic>?;
      final motdLines = json['motd']?['clean'] as List?;

      return ServerStatus(
        online: true,
        playersOnline: players?['online'] as int? ?? 0,
        playersMax: players?['max'] as int? ?? 0,
        motd: motdLines?.join(' ') ?? '',
      );
    } catch (_) {
      return ServerStatus.offline;
    }
  }
}
