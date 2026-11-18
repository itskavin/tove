import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'orb.dart';

/// Debug page: cycles every [OrbState] with a fake audio level so the orb
/// can be checked on a device. Not shown to users; hook it into a debug
/// menu. The fake level only exists here; the real orb never fakes speech.
class OrbDemoPage extends StatefulWidget {
  const OrbDemoPage({
    super.key,
    this.stepDuration = const Duration(seconds: 3),
  });

  /// Time spent in each state while cycling.
  final Duration stepDuration;

  @override
  State<OrbDemoPage> createState() => _OrbDemoPageState();
}

class _OrbDemoPageState extends State<OrbDemoPage> {
  static const _states = [
    OrbState.connecting,
    OrbState.listening,
    OrbState.userSpeaking,
    OrbState.thinking,
    OrbState.assistantSpeaking,
    OrbState.muted,
    OrbState.error,
    OrbState.ended,
  ];

  final ValueNotifier<double> _level = ValueNotifier(0);
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _cycle, _poll;
  int _index = 0;
  bool _running = true;
  bool _docked = false;
  OrbRenderer _renderer = OrbRenderer.auto;
  bool _reduce = false;

  OrbState get _state => _states[_index];

  @override
  void initState() {
    super.initState();
    _cycle = Timer.periodic(widget.stepDuration, (_) {
      if (_running) _go(_index + 1);
    });
    // Same cadence as the live level poll (50 ms).
    _poll = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _fakeLevel(),
    );
  }

  void _go(int i) => setState(() => _index = i % _states.length);

  void _fakeLevel() {
    final speaks =
        _state == OrbState.userSpeaking || _state == OrbState.assistantSpeaking;
    if (!speaks) {
      _level.value = 0;
      return;
    }
    // Syllable-like bursts: 4–5 Hz with a slower phrase envelope.
    final t = _clock.elapsedMilliseconds / 1000;
    final syllable = math.max(0.0, math.sin(t * 2 * math.pi * 4.3));
    final phrase = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 0.35);
    _level.value = (0.25 + 0.75 * syllable * phrase).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _poll?.cancel();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final size = Sz.orbCentered(width);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(title: const Text('Orb demo')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: HermesOrb(
                state: _state,
                size: size,
                level: _level,
                docked: _docked,
                renderer: _renderer,
                reduceMotion: _reduce ? true : null,
              ),
            ),
          ),
          Text(_state.name, style: TextStyle(color: t.text, fontSize: 17)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < _states.length; i++)
                ChoiceChip(
                  label: Text(_states[i].name),
                  selected: i == _index,
                  onSelected: (_) => _go(i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilterChip(
                label: const Text('Cycle'),
                selected: _running,
                onSelected: (v) => setState(() => _running = v),
              ),
              FilterChip(
                label: const Text('Docked'),
                selected: _docked,
                onSelected: (v) => setState(() => _docked = v),
              ),
              FilterChip(
                label: const Text('Painter'),
                selected: _renderer == OrbRenderer.fallback,
                onSelected: (v) => setState(
                  () => _renderer = v ? OrbRenderer.fallback : OrbRenderer.auto,
                ),
              ),
              FilterChip(
                label: const Text('Reduce motion'),
                selected: _reduce,
                onSelected: (v) => setState(() => _reduce = v),
              ),
            ],
          ),
          SizedBox(height: 16 + MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }
}
