import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../brand.dart';

/// Why pairing failed, in terms the person holding the phone can act on.
enum PairingProblem {
  /// No answer: offline, another network, Tailscale off, wrong address.
  unreachable,

  /// The code was used already, or its 10 minutes are over.
  expired,

  /// The bridge does not know this code.
  wrongCode,

  /// Too many wrong codes; the bridge waits a few minutes.
  tooManyTries,

  /// The address is plain `http://` to another machine, which the app may
  /// not use (and would send the key unencrypted).
  insecure,

  /// A bridge from before pairing codes (no `POST /api/pair`).
  unsupported,

  /// Anything else the server answered.
  server,
}

class PairingException implements Exception {
  const PairingException(this.problem, {this.retryAfter});

  final PairingProblem problem;

  /// For [PairingProblem.tooManyTries], when the server said.
  final Duration? retryAfter;

  /// One or two plain sentences for the screen.
  String get message => switch (problem) {
    PairingProblem.unreachable =>
      'Couldn’t reach your ${Brand.serverName}. Check that this phone is '
          'online. If your setup uses Tailscale, turn Tailscale on here too.',
    PairingProblem.expired =>
      'This code has expired or was already used. Ask Hermes for a new one: '
          '“pair Tove again”.',
    PairingProblem.wrongCode =>
      'That code isn’t right. Check it and try again.',
    PairingProblem.tooManyTries =>
      'Too many tries. Wait ${_minutes(retryAfter)} and try again.',
    PairingProblem.insecure =>
      'This address isn’t secure (it starts with http://), so Tove can’t use '
          'it. Ask Hermes to set up Tailscale or another HTTPS address.',
    PairingProblem.unsupported =>
      'This ${Brand.serverName} is too old for pairing codes. Update the Tove '
          'bridge, or connect with an access key instead.',
    PairingProblem.server =>
      'Your ${Brand.serverName} had a problem. Try again, or ask Hermes to '
          'check the Tove bridge.',
  };

  static String _minutes(Duration? d) {
    final m = d == null ? 0 : (d.inSeconds / 60).ceil();
    return m <= 1 ? 'a minute' : '$m minutes';
  }

  @override
  String toString() => 'PairingException($problem)';
}

/// The bridge's answer to a good code.
class PairResult {
  const PairResult({required this.key, this.name});
  final String key;
  final String? name;
}

/// Trades a pairing code for the access key; throws [PairingException].
typedef Pairer = Future<PairResult> Function(Uri server, String code);

/// Whether [server] is plain http to something other than this device.
bool insecureAddress(Uri server) {
  if (server.scheme != 'http') return false;
  final h = server.host.toLowerCase();
  return !(h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]');
}

/// `POST /api/pair` (server/API.md "Pairing").
Future<PairResult> pairWithBridge(
  Uri server,
  String code, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 15),
}) async {
  // The web app is served by its own bridge; elsewhere plain http is refused
  // by the platform (Android release builds) and would expose the key.
  if (!kIsWeb && insecureAddress(server)) {
    throw const PairingException(PairingProblem.insecure);
  }
  final c = client ?? http.Client();
  final url = server.replace(path: '${server.path}/api/pair');
  final http.Response r;
  try {
    r = await c
        .post(
          url,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code': code}),
        )
        .timeout(timeout);
  } on TimeoutException {
    throw const PairingException(PairingProblem.unreachable);
  } catch (_) {
    throw const PairingException(PairingProblem.unreachable);
  } finally {
    if (client == null) c.close();
  }
  Map<String, dynamic>? body;
  try {
    final decoded = jsonDecode(r.body);
    if (decoded is Map<String, dynamic>) body = decoded;
  } catch (_) {}
  final errorCode = body?['code'];
  switch (r.statusCode) {
    case 200:
      final key = body?['key'];
      if (key is! String || key.length < 20) {
        throw const PairingException(PairingProblem.server);
      }
      final name = body?['name'];
      return PairResult(key: key, name: name is String ? name : null);
    case 410:
      throw const PairingException(PairingProblem.expired);
    case 401 || 400 when errorCode != 'pairing_off':
      throw const PairingException(PairingProblem.wrongCode);
    case 429:
      final s = body?['retry_after_s'];
      throw PairingException(
        PairingProblem.tooManyTries,
        retryAfter: s is num ? Duration(seconds: s.ceil()) : null,
      );
    // An old bridge: no such route (404), or a proxy's page without JSON.
    case 404 || 405 when errorCode == null || errorCode == 'not_found':
      throw const PairingException(PairingProblem.unsupported);
    default:
      throw const PairingException(PairingProblem.server);
  }
}
