import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import '../theme/render_policy.dart';
import '../theme/tokens.dart';

enum ToastKind { info, success, warning, error }

class ToastData {
  ToastData(
    this.message, {
    this.kind = ToastKind.info,
    this.actionLabel,
    this.onAction,
    this.dismissible = true,
  });

  final String message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool dismissible;
}

/// One toast at a time; a newer one replaces the older (§5.10). Toasts
/// without an action dismiss themselves after 4 s.
class ToastController extends ChangeNotifier {
  ToastController({this.autoDismiss = const Duration(seconds: 4)});

  final Duration autoDismiss;
  ToastData? _current;
  Timer? _timer;

  ToastData? get current => _current;

  void show(
    String message, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _timer?.cancel();
    _current = ToastData(
      message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    if (onAction == null) _timer = Timer(autoDismiss, dismiss);
    notifyListeners();
  }

  void dismiss() {
    _timer?.cancel();
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Shows [ToastController.current] as a floating capsule under the app bar.
class ToastHost extends StatelessWidget {
  const ToastHost({super.key, required this.controller, this.top = 64});

  final ToastController controller;
  final double top;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final data = controller.current;
        return Positioned(
          top: MediaQuery.paddingOf(context).top + top,
          left: Sp.controls,
          right: Sp.controls,
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: Motion.of(context, const Duration(milliseconds: 220)),
              reverseDuration: Motion.of(
                context,
                const Duration(milliseconds: 160),
              ),
              switchInCurve: Motion.emphasizedDecel,
              switchOutCurve: Motion.exit,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, -0.25),
                    end: Offset.zero,
                  ).animate(a),
                  child: child,
                ),
              ),
              child: data == null
                  ? const SizedBox.shrink()
                  : _Toast(
                      key: ObjectKey(data),
                      data: data,
                      onClose: controller.dismiss,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({super.key, required this.data, required this.onClose});
  final ToastData data;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final blur = RenderPolicyScope.of(context).blur;
    final (icon, color) = switch (data.kind) {
      ToastKind.info => (Icons.info_outline_rounded, t.textMuted),
      ToastKind.success => (Icons.check_circle_outline_rounded, t.success),
      ToastKind.warning => (Icons.info_outline_rounded, t.warning),
      ToastKind.error => (Icons.error_outline_rounded, t.danger),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Rad.toast),
      side: BorderSide(color: t.outline, width: 0.5),
    );
    Widget body = DecoratedBox(
      decoration: ShapeDecoration(
        color: blur ? t.sheet : t.sheetFallback,
        shape: shape,
        shadows: t.dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 32,
                  offset: Offset(0, 8),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(data.message, style: t.toast),
                ),
              ),
              if (data.onAction != null)
                TextButton(
                  onPressed: () {
                    onClose();
                    data.onAction!();
                  },
                  child: Text(data.actionLabel ?? 'Retry'),
                ),
              if (data.dismissible)
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: onClose,
                  icon: Icon(Icons.close_rounded, size: 18, color: t.textMuted),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
    if (blur) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(Rad.toast),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: body,
        ),
      );
    }
    return Semantics(
      liveRegion: true,
      container: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: body,
      ),
    );
  }
}
