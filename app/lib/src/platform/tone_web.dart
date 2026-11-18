import 'package:web/web.dart' as web;

web.AudioContext? _ctx;

/// Plays short sine tones with Web Audio (no audio files).
void play(List<(double, int)> tones, double gain) {
  try {
    final ctx = _ctx ??= web.AudioContext();
    var t = ctx.currentTime + 0.01;
    for (final (hz, ms) in tones) {
      final osc = ctx.createOscillator();
      final g = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = hz;
      final dur = ms / 1000;
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(gain, t + 0.008);
      g.gain.linearRampToValueAtTime(0, t + dur);
      osc.connect(g);
      g.connect(ctx.destination);
      osc.start(t);
      osc.stop(t + dur + 0.01);
      t += dur;
    }
  } catch (_) {
    // No audio output available; cues are optional.
  }
}
