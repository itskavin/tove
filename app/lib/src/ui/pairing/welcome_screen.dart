import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand.dart';
import '../../config.dart';
import '../../pairing/pair_link.dart';
import '../../pairing/pairing.dart';
import '../../settings/settings.dart';
import '../onboarding_screen.dart';
import '../orb/orb.dart';
import '../theme/tokens.dart';
import 'pairing_page.dart';
import 'scan_page.dart';

/// Hermes Agent's official getting-started docs.
const kHermesDocsUrl =
    'https://hermes-agent.nousresearch.com/docs/getting-started/installation';

/// Whether this device can scan: phones and tablets (the camera plugin's
/// Android and iOS builds). The web and desktop apps pair by typing.
bool get canScanHere =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Opens [url] outside the app; false when nothing could.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> openExternal(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// First run: what Tove is, and the two ways to connect (scan the QR code
/// Hermes shows, or type its address and code).
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({
    super.key,
    required this.settings,
    this.verify = verifyWithBridge,
    this.pair = pairWithBridge,
    this.scan = scanQrCode,
    this.openUrl = openExternal,
    this.canScan,
  });

  final SettingsController settings;
  final KeyVerifier verify;
  final Pairer pair;
  final QrScanner scan;
  final UrlOpener openUrl;

  /// Null: phones and tablets only ([canScanHere]).
  final bool? canScan;

  bool get _scanHere => canScan ?? canScanHere;

  Future<void> _scan(BuildContext context) async {
    final text = await scan(context);
    if (!context.mounted || text == null) return;
    if (text == ScanPage.enterByHand) return _manual(context);
    final link = PairLink.parse(text);
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That QR code isn’t a Tove pairing code. Ask Hermes to '
            '“set up Tove” for the right one.',
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PairingPage(
          link: link,
          settings: settings,
          pair: pair,
          verify: verify,
        ),
      ),
    );
  }

  Future<void> _manual(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          ManualPairPage(settings: settings, verify: verify, pair: pair),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final loadError = settings.loadError;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(
                    child: HermesOrb(state: OrbState.idle, size: 120),
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      Brand.appName,
                      style: t.display,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Chat with your own Hermes agent, or just talk.',
                    style: t.row.copyWith(color: t.textMuted).hermesWeight(400),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Hermes Agent is a free, open-source AI assistant that you '
                    'run on your own computer or server. Tove is an app for it.',
                    style: t.caption,
                    textAlign: TextAlign.center,
                  ),
                  Center(
                    child: TextButton(
                      onPressed: () => openUrl(Uri.parse(kHermesDocsUrl)),
                      child: const Text('How do I get Hermes?'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'To connect, ask your Hermes to “set up Tove”. It shows '
                    'a QR code and a short code.',
                    style: t.row.hermesWeight(400),
                    textAlign: TextAlign.center,
                  ),
                  if (loadError != null) ...[
                    const SizedBox(height: 16),
                    Text(loadError, style: t.label.copyWith(color: t.danger)),
                  ],
                  const SizedBox(height: 24),
                  if (_scanHere) ...[
                    FilledButton.icon(
                      onPressed: () => _scan(context),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('Scan QR code'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _manual(context),
                      child: const Text('Enter code or address'),
                    ),
                  ] else
                    FilledButton(
                      onPressed: () => _manual(context),
                      child: const Text('Enter code or address'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The address and the short code, typed; or, for an existing setup, the
/// address and the access key (the old connect screen).
class ManualPairPage extends StatefulWidget {
  const ManualPairPage({
    super.key,
    required this.settings,
    required this.verify,
    required this.pair,
  });

  final SettingsController settings;
  final KeyVerifier verify;
  final Pairer pair;

  @override
  State<ManualPairPage> createState() => _ManualPairPageState();
}

class _ManualPairPageState extends State<ManualPairPage> {
  late final _url = TextEditingController(
    text: widget.settings.url.isNotEmpty
        ? widget.settings.url
        : defaultBridgeUrl(),
  );
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final server = PairLink.parseServer(_url.text)!;
    final code = PairLink.normalizeCode(_code.text)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await completePairing(
        settings: widget.settings,
        pair: widget.pair,
        verify: widget.verify,
        server: server,
        code: code,
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The key could not be saved on this device.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useKey() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingScreen(
          settings: widget.settings,
          verify: widget.verify,
          editing: true,
        ),
      ),
    );
    if (mounted && widget.settings.hasKey) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Enter code')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Type the server address and the pairing code that '
                      'Hermes showed you.',
                      style: t.row
                          .copyWith(color: t.textMuted)
                          .hermesWeight(400),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: kExampleBridgeUrl,
                      ),
                      validator: (v) => PairLink.parseServer(v) == null
                          ? 'Enter an address such as $kExampleBridgeUrl'
                          : null,
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _code,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9\- ]'),
                        ),
                        LengthLimitingTextInputFormatter(40),
                      ],
                      style: t.row.copyWith(
                        fontFamily: 'JetBrainsMono',
                        letterSpacing: 1.5,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Pairing code',
                        hintText: 'ABCDE-FGHJK',
                        helperText: 'Works once, for 10 minutes.',
                      ),
                      validator: (v) => PairLink.normalizeCode(v) == null
                          ? 'Enter the code, such as ABCDE-FGHJK'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: t.label.copyWith(color: t.danger),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: t.onAccent,
                                semanticsLabel: 'Connecting',
                              ),
                            )
                          : const Text('Connect'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _useKey,
                      child: const Text('I have an access key instead'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
