import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../theme/render_policy.dart';
import '../theme/tokens.dart';

/// A frosted surface (§3.6): blur inside its own clip, a translucent fill and
/// a 0.5 dp inner stroke. With blur off (§7.3) it is an opaque surface.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.shape = const StadiumBorder(),
    this.fill,
    this.sigma = 20,
    this.opaque = false,
  });

  final Widget child;
  final OutlinedBorder shape;

  /// Overrides the glass fill (for example `closeFill` while muted).
  final Color? fill;
  final double sigma;

  /// Forces the fallback fill, for example while something bright is behind
  /// the control (§8.1).
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final blur = RenderPolicyScope.of(context).blur && !opaque && fill == null;
    final color = fill ?? (blur ? t.glass : t.glassFallback);
    final decorated = DecoratedBox(
      decoration: ShapeDecoration(
        color: color,
        shape: shape.copyWith(
          side: BorderSide(
            color: t.glassStroke,
            width: 0.5,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
      ),
      child: child,
    );
    if (!blur) return decorated;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: decorated,
      ),
    );
  }
}

/// A round glass button: [size] visual, at least 48 dp to hit (§3.5).
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.size = Sz.glassButton,
    this.fill,
    this.tooltip,
    this.toggled,
    this.opaque = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;
  final double size;
  final Color? fill;
  final String? tooltip;
  final bool? toggled;
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final hit = size < Sz.hit ? Sz.hit : size;
    // Its own node: a round button's label and bounds never merge into
    // whatever holds it.
    Widget button = Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      toggled: toggled,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: FocusRing(
        shape: const CircleBorder(),
        onActivate: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: hit,
            child: Center(
              child: PressScale(
                enabled: onPressed != null,
                child: SizedBox.square(
                  dimension: size,
                  child: Glass(
                    shape: const CircleBorder(),
                    fill: fill,
                    opaque: opaque,
                    child: Center(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(
        message: tooltip!,
        excludeFromSemantics: true,
        child: button,
      );
    }
    return button;
  }
}

/// A solid round button (the light × "end live", the composer action).
class SolidRoundButton extends StatelessWidget {
  const SolidRoundButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    required this.color,
    this.size = Sz.liveControl,
    this.tooltip,
    this.toggled,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;
  final Color color;
  final double size;
  final String? tooltip;
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final hit = size < Sz.hit ? Sz.hit : size;
    // Its own node: a round button's label and bounds never merge into
    // whatever holds it.
    Widget b = Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      toggled: toggled,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: FocusRing(
        shape: const CircleBorder(),
        onActivate: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: hit,
            child: Center(
              child: PressScale(
                enabled: onPressed != null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: onPressed == null
                        ? color.withValues(alpha: 0.5)
                        : color,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(
                    dimension: size,
                    child: Center(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      b = Tooltip(message: tooltip!, excludeFromSemantics: true, child: b);
    }
    return b;
  }
}

/// Shrinks its child slightly while pressed.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (widget.enabled && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: Duration(milliseconds: _down ? 90 : 160),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Keyboard focus (§8.1): a 2 dp accent ring with a 2 dp offset, and
/// Enter/Space activation.
class FocusRing extends StatefulWidget {
  const FocusRing({
    super.key,
    required this.child,
    this.onActivate,
    this.shape = const StadiumBorder(),
    this.focusNode,
  });

  final Widget child;
  final VoidCallback? onActivate;
  final ShapeBorder shape;
  final FocusNode? focusNode;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      enabled: widget.onActivate != null,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate?.call();
            return null;
          },
        ),
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: _focused
              ? _inset(widget.shape, t.accent)
              : _inset(widget.shape, Colors.transparent),
        ),
        child: widget.child,
      ),
    );
  }

  ShapeBorder _inset(ShapeBorder s, Color c) {
    final side = BorderSide(
      color: c,
      width: 2,
      strokeAlign: BorderSide.strokeAlignOutside,
    );
    return switch (s) {
      CircleBorder() => CircleBorder(side: side),
      RoundedRectangleBorder(:final borderRadius) => RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: side,
      ),
      _ => StadiumBorder(side: side),
    };
  }
}
