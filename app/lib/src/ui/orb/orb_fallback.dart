import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../theme/tokens.dart';
import 'orb_engine.dart';

/// The orb without a fragment shader (spec §7.3): the same sky-window model
/// drawn with gradients and at most three blurred shapes, and no save
/// layers. Used on the web, on Android below API 29, when the shader fails
/// to load, when the frame-time monitor asks for cheaper effects, and (still,
/// at time 0) with reduced motion.
///
/// [r] is the visible radius; [f] the current frame.
void paintFallbackOrb(Canvas canvas, Offset centre, double r, OrbFrame f) {
  if (r <= 0.5 || f.opacity <= 0.001) return;
  final circle = Path()..addOval(Rect.fromCircle(center: centre, radius: r));
  final alpha = f.opacity.clamp(0.0, 1.0);

  Color tone(Color c) {
    // Muted desaturation (to 35 %, then × 0.85) and speech brightness.
    // Same luma weights as orb.frag, so both renderers mute alike.
    final l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    final grey = Color.from(alpha: 1, red: l, green: l, blue: l);
    final col = Color.lerp(grey, c, f.saturation)!;
    final dim =
        (0.85 + 0.15 * ((f.saturation - 0.35) / 0.65).clamp(0.0, 1.0)) *
        (1 + f.brightness);
    return Color.from(
      alpha: alpha,
      red: (col.r * dim).clamp(0.0, 1.0),
      green: (col.g * dim).clamp(0.0, 1.0),
      blue: (col.b * dim).clamp(0.0, 1.0),
    );
  }

  final top = tone(
    Color.lerp(OrbPalette.skyTop, OrbPalette.errorSkyTop, f.errorMix)!,
  );
  final low = tone(
    Color.lerp(OrbPalette.skyLow, OrbPalette.errorSkyLow, f.errorMix)!,
  );
  final cloud = tone(OrbPalette.cloud);
  final shade = tone(OrbPalette.cloudShade);

  canvas.save();
  canvas.clipPath(circle);
  canvas.translate(centre.dx, centre.dy);
  canvas.rotate(f.tilt);

  // Horizon in the disc (y down): cloudLevel 0 → bottom, 1 → top.
  final horizon = (1 - 2 * f.cloudLevel) * r;
  final big = r * 1.5;
  canvas.drawRect(
    Rect.fromLTRB(-big, -big, big, big),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, -r),
        Offset(0, math.max(horizon, -r + 1)),
        [top, low],
      ),
  );

  // The bank: fills below a wavy horizon, soft top edge (blur 1 of 3).
  final t = f.time;
  final wave = r * 0.09 * f.turbulence;
  final body = Path()..moveTo(-big, horizon);
  const steps = 24;
  for (var i = 0; i <= steps; i++) {
    final x = -r + 2 * r * i / steps;
    final y =
        horizon +
        wave * math.sin(x / r * 2.4 + f.drift * 6 + t * 0.4 + f.roll) +
        wave * 0.5 * math.sin(x / r * 5.1 - f.drift * 9 + t * 0.7 + 1.3);
    body.lineTo(x, y);
  }
  body
    ..lineTo(big, big)
    ..lineTo(-big, big)
    ..close();
  canvas.drawPath(
    body,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, horizon),
        Offset(0, math.max(r, horizon + 1)),
        [cloud, cloud, shade],
        const [0, 0.35, 1],
      )
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.06),
  );
  // Two shaded billows for depth (blurs 2 and 3 of 3).
  for (final (dx, dy, k, ph) in const [
    (-0.45, 0.35, 0.42, 0.0),
    (0.4, 0.55, 0.38, 2.1),
  ]) {
    final cx = r * dx + r * 0.08 * math.sin(f.drift * 5 + ph + f.roll);
    final cy = horizon + (r - horizon) * dy;
    canvas.drawCircle(
      Offset(cx, cy),
      r * k,
      Paint()
        ..color = shade.withValues(alpha: 0.45 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.18),
    );
  }
  canvas.restore();

  // 1 dp inner rim.
  canvas.drawCircle(
    centre,
    r - 0.5,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = OrbPalette.rim.withValues(alpha: OrbPalette.rim.a * alpha),
  );
}
