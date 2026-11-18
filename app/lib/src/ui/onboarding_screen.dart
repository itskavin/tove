import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/bridge_api.dart';
import '../config.dart';
import '../settings/settings.dart';
import 'orb/orb.dart';
import 'theme/motion.dart';
import 'theme/tokens.dart';
import '../brand.dart';

typedef KeyVerifier = Future<void> Function(Uri url, String key);

Future<void> verifyWithBridge(Uri url, String key) async {
  final api = BridgeApi(baseUrl: url, accessKey: key);
  try {
    await api.verifyKey();
  } finally {
    api.close();
  }
}

/// First run (and "change server or key"): the bridge address and access key.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.settings,
    this.verify = verifyWithBridge,
    this.editing = false,
  });

  final SettingsController settings;
  final KeyVerifier verify;

  /// Opened from Settings rather than on first launch.
  final bool editing;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  // The light error shake: 0, −6, 6, −4, 4, 0 dp over 320 ms (§6.9).
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  static final _shakeOffsets = TweenSequence<double>([
    for (final (a, b) in const [
      (0.0, -6.0),
      (-6.0, 6.0),
      (6.0, -4.0),
      (-4.0, 4.0),
      (4.0, 0.0),
    ])
      TweenSequenceItem(
        tween: Tween(begin: a, end: b),
        weight: 1,
      ),
  ]);
  late final _url = TextEditingController(text: widget.settings.url);
  final _key = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _show = false;
  bool _busy = false;
  String? _error;
  bool _offerSaveAnyway = false;

  @override
  void dispose() {
    _shake.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit({bool skipCheck = false}) async {
    if (!_form.currentState!.validate()) return;
    final url = BridgeApi.parseUrl(_url.text)!;
    final key = _key.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _offerSaveAnyway = false;
    });
    try {
      if (!skipCheck) await widget.verify(url, key);
      await widget.settings.saveConnection(url: url.toString(), key: key);
      if (mounted && widget.editing) Navigator.of(context).pop();
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.unauthorized
            ? 'That key was rejected by the server.'
            : '${e.message}. Check the address and that this device can '
                  'reach the server.';
        _offerSaveAnyway = !e.unauthorized;
      });
      if (e.unauthorized && !Motion.reduced(context)) {
        _shake.forward(from: 0);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'The key could not be saved to secure storage.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final loadError = widget.settings.loadError;
    return Scaffold(
      appBar: widget.editing
          ? AppBar(title: const Text('Server and access key'))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!widget.editing) ...[
                        Center(
                          child: HermesOrb(
                            state: _busy ? OrbState.connecting : OrbState.idle,
                            size: 120,
                          ),
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
                          style: t.row
                              .copyWith(color: t.textMuted)
                              .hermesWeight(400),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                      ],
                      if (loadError != null) ...[
                        Text(
                          loadError,
                          style: t.label.copyWith(color: t.danger),
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _url,
                        enabled: !_busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.url],
                        decoration: InputDecoration(
                          labelText: 'Server address',
                          hintText: kExampleBridgeUrl,
                          helperText: kIsWeb
                              ? 'The web app can only reach the server it was '
                                    'opened from.'
                              : 'The HTTPS address of your Tove bridge.',
                          helperMaxLines: 3,
                        ),
                        validator: (v) => BridgeApi.parseUrl(v ?? '') == null
                            ? 'Enter an address such as $kExampleBridgeUrl'
                            : null,
                      ),
                      const SizedBox(height: 18),
                      AnimatedBuilder(
                        animation: _shake,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(
                            _shake.isAnimating
                                ? _shakeOffsets.transform(_shake.value)
                                : 0,
                            0,
                          ),
                          child: child,
                        ),
                        child: TextFormField(
                          controller: _key,
                          enabled: !_busy,
                          obscureText: !_show,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          inputFormatters: [
                            FilteringTextInputFormatter.deny(RegExp(r'\s')),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Access key',
                            helperText:
                                'LIVE_PAGE_KEY from the bridge’s bridge.env. '
                                'Stored in this device’s secure storage.',
                            helperMaxLines: 3,
                            suffixIcon: IconButton(
                              tooltip: _show ? 'Hide key' : 'Show key',
                              icon: Icon(
                                _show
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                              ),
                              onPressed: () => setState(() => _show = !_show),
                            ),
                          ),
                          validator: (v) {
                            final k = (v ?? '').trim();
                            if (k.isEmpty) return 'Enter the access key';
                            if (k.length < kMinKeyLength) {
                              return 'That is too short to be the access key';
                            }
                            return null;
                          },
                        ),
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
                                  semanticsLabel: 'Checking',
                                ),
                              )
                            : Text(
                                widget.editing ? 'Check and save' : 'Connect',
                              ),
                      ),
                      if (_offerSaveAnyway) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _submit(skipCheck: true),
                          child: const Text('Save without checking'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
