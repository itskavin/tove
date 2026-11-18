import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/theme/motion.dart';
import '../ui/theme/tokens.dart';
import 'reply_notice.dart';
import 'reply_notifier.dart';

/// The in-app "reply finished in another chat" banner: chat title, a short
/// preview, **View** and a close button. Put it in the shell's top-level
/// `Stack` (like `ToastHost`); it is a `Positioned` and renders
/// [ReplyNotifier.current]. Announced to screen readers as a live region.
class ReplyNoticeBanner extends StatelessWidget {
  const ReplyNoticeBanner({super.key, required this.notifier, this.top = 64});

  final ReplyNotifier notifier;

  /// Distance below the safe area (the toast uses the same default).
  final double top;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReplyNotice?>(
      valueListenable: notifier.current,
      builder: (context, notice, _) => Positioned(
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
            child: notice == null
                ? const SizedBox.shrink()
                : ReplyNoticeCard(
                    key: ObjectKey(notice),
                    notice: notice,
                    onView: notice.conversationId == null
                        ? null
                        : () => notifier.view(notice),
                    onClose: notifier.dismiss,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The banner's card, usable on its own (tests, custom hosts).
class ReplyNoticeCard extends StatelessWidget {
  const ReplyNoticeCard({
    super.key,
    required this.notice,
    this.onView,
    this.onClose,
  });

  final ReplyNotice notice;
  final VoidCallback? onView;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final failed = notice.kind == ReplyNoticeKind.failed;
    return Semantics(
      liveRegion: true,
      container: true,
      label: '${notice.heading}. ${notice.body}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: scheme.shadow.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onView,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      failed
                          ? Icons.error_outline_rounded
                          : Icons.mark_chat_read_outlined,
                      size: 20,
                      color: failed ? scheme.error : scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notice.heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge,
                          ),
                          Text(
                            notice.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (onView != null)
                    TextButton(onPressed: onView, child: const Text('View')),
                  if (onClose != null)
                    IconButton(
                      tooltip: 'Dismiss',
                      iconSize: 18,
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded),
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

/// Shows [ReplyNoticeBanner] above every route: put it in
/// `MaterialApp.builder` around the navigator. A banner raised while a page
/// such as Settings covers the chat (Settings › Notifications › Send a test,
/// or a reply finishing in another chat) is then still seen. It has its own
/// [Overlay] (the card's tooltip needs one) and lets every touch outside
/// the card through to the app.
class ReplyBannerLayer extends StatefulWidget {
  const ReplyBannerLayer({
    super.key,
    required this.notifier,
    required this.child,
  });

  /// The signed-in session's notifier; null while there is none.
  final ValueListenable<ReplyNotifier?> notifier;
  final Widget child;

  @override
  State<ReplyBannerLayer> createState() => _ReplyBannerLayerState();
}

class _ReplyBannerLayerState extends State<ReplyBannerLayer> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => ValueListenableBuilder<ReplyNotifier?>(
      valueListenable: widget.notifier,
      builder: (context, n, _) =>
          n == null ? const SizedBox.shrink() : ReplyNoticeBanner(notifier: n),
    ),
  );

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned.fill(child: Overlay(initialEntries: [_entry])),
    ],
  );
}
