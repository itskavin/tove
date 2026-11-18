/// A pairing invitation: the bridge's address and a one-time code that the
/// bridge trades for its access key (server/API.md "Pairing").
///
/// The Hermes skill `tove-setup` (or `tove_pair.py` on the server) shows it as
/// a QR code holding `tove://pair?u=<address>&c=<code>[&n=<name>]`. The
/// access key itself is never in the link.
class PairLink {
  const PairLink({required this.server, required this.code, this.name});

  /// The bridge's address as this device reaches it.
  final Uri server;

  /// The canonical code: upper case, no separators.
  final String code;

  /// The server's display name, if the link carried one.
  final String? name;

  /// Characters a pairing code is made of (no 0/O and 1/I look-alikes).
  static const alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  /// Shortest and longest code accepted (the bridge makes 10).
  static const minCode = 6, maxCode = 32;

  /// What the user typed (or the link held) as a canonical code, or null when
  /// it cannot be one. Lower case, spaces and dashes are fine (the bridge
  /// ignores them the same way).
  static String? normalizeCode(String? input) {
    if (input == null) return null;
    final buf = StringBuffer();
    for (final rune in input.toUpperCase().runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '-' || ch == '_' || ch == '.') continue;
      if (!RegExp(r'^[0-9A-Z]$').hasMatch(ch)) return null;
      buf.write(ch);
    }
    final code = buf.toString();
    if (code.length < minCode || code.length > maxCode) return null;
    return code;
  }

  /// `ABCDE-FGHJK` for display.
  static String pretty(String code) =>
      code.length == 10 ? '${code.substring(0, 5)}-${code.substring(5)}' : code;

  /// A bridge address from a link or user input: http(s) with a host, no
  /// query or fragment, no trailing slash. Null otherwise.
  static Uri? parseServer(String? input) {
    final text = (input ?? '').trim();
    if (text.isEmpty) return null;
    final u = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (u == null || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
    if (u.scheme != 'https' && u.scheme != 'http') return null;
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: path,
    );
  }

  /// Parses `tove://pair?u=…&c=…[&n=…]`, the only form a QR code carries.
  /// Null for anything else, including other `tove://` links.
  static PairLink? parse(String? text) {
    if (text == null) return null;
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'tove' || uri.host != 'pair') return null;
    if (uri.pathSegments.any((s) => s.isNotEmpty)) return null;
    final q = uri.queryParameters;
    final server = parseServer(q['u']);
    final code = normalizeCode(q['c']);
    if (server == null || code == null) return null;
    final name = q['n']?.trim();
    return PairLink(
      server: server,
      code: code,
      name: name == null || name.isEmpty
          ? null
          : (name.length > 60 ? name.substring(0, 60) : name),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PairLink &&
      other.server == server &&
      other.code == code &&
      other.name == name;

  @override
  int get hashCode => Object.hash(server, code, name);

  @override
  String toString() => 'PairLink($server, ${pretty(code)})';
}
