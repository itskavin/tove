import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../bridge/bridge_api.dart';
import '../../pairing/pair_link.dart';
import '../../pairing/pairing.dart';
import '../../settings/settings.dart';
import '../onboarding_screen.dart' show KeyVerifier;
import '../orb/orb.dart';
import '../theme/tokens.dart';

/// Trades the code, checks the key, saves the connection. Throws
/// [PairingException]; on success the app's home becomes the chat.
Future<void> completePairing({
  required SettingsController settings,
  required Pairer pair,
  required KeyVerifier verify,
  required Uri server,
  required String code,
}) async {
  final result = await pair(server, code);
  try {
    await verify(server, result.key);
  } on BridgeException catch (e) {
    throw PairingException(
      e.unreachable ? PairingProblem.unreachable : PairingProblem.server,
    );
  }
  await settings.saveConnection(url: server.toString(), key: result.key);
}

/// A scanned or tapped pairing link: connects at once, and explains what to
/// do when it cannot.
class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.link,
    required this.settings,
    required this.pair,
    required this.verify,
  });

  final PairLink link;
  final SettingsController settings;
  final Pairer pair;
  final KeyVerifier verify;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  PairingException? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  String get _where => widget.link.name ?? widget.link.server.host;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await completePairing(
        settings: widget.settings,
        pair: widget.pair,
        verify: widget.verify,
        server: widget.link.server,
        code: widget.link.code,
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e);
    } catch (_) {
      // Secure storage refused the key.
      if (mounted) {
        setState(() => _error = const PairingException(PairingProblem.server));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final error = _error;
    final retryable =
        error != null &&
        const {
          PairingProblem.unreachable,
          PairingProblem.server,
          PairingProblem.tooManyTries,
        }.contains(error.problem);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: HermesOrb(
                      state: _busy ? OrbState.connecting : OrbState.idle,
                      size: 96,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      _busy
                          ? 'Connecting to $_where…'
                          : 'Couldn’t connect to $_where',
                      style: t.title,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error.message,
                        style: t.row
                            .copyWith(color: t.textMuted)
                            .hermesWeight(400),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (retryable)
                      FilledButton(
                        onPressed: _run,
                        child: const Text('Try again'),
                      ),
                    if (retryable) const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Back'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
