import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../common/glyphs.dart';
import '../common/popover.dart';
import '../feedback.dart';
import '../interactive/interactive.dart' show hermesUiPlainText;
import '../live/live_content.dart' show extractSites, hasSourceIndex, LiveSite;
import '../live/live_link_cards.dart' show LiveSourcesPill;
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../shell/drawer_swipe.dart' show DrawerSwipeTarget;
import '../tasks/conversation_tasks.dart' show taskFailureText;
import 'attachment_views.dart';
import 'message_actions.dart';
import 'message_markdown.dart';
import 'reply_details.dart';
import 'work_line.dart';
import '../../brand.dart';

/// Plays the message entry once (spec §6.3): opacity 0 → 1, +12 → 0 dp and
/// scale 0.97 → 1 from the bottom right, 220 ms emphasizedDecel, after
/// [delay]. No motion under reduced motion.
class MessageEntry extends StatefulWidget {
  const MessageEntry({
    super.key,
    required this.child,
    this.animate = true,
    this.delay = Duration.zero,
    this.alignment = Alignment.bottomRight,
  });

  final Widget child;
  final bool animate;
  final Duration delay;
  final Alignment alignment;

  @override
  State<MessageEntry> createState() => _MessageEntryState();
}

class _MessageEntryState extends State<MessageEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.animate) {
      _c.value = 1;
    }
    // Drop the transition widgets once the entry has played.
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.value == 1 || _c.isAnimating) return;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c.value == 1 && !_c.isAnimating) return widget.child;
    final a = CurvedAnimation(parent: _c, curve: Motion.emphasizedDecel);
    return FadeTransition(
      opacity: a,
      child: AnimatedBuilder(
        animation: a,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 12 * (1 - a.value)),
          child: Transform.scale(
            scale: 0.97 + 0.03 * a.value,
            alignment: widget.alignment,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A user turn (spec §4.3): right-aligned `surface` bubble, radius 22.
class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.message, this.onLongPress});

  final ChatMessage message;
  final void Function(BuildContext anchor)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final voice = message.isVoice;
    final bubble = message.text.trim().isEmpty && message.attachments.isNotEmpty
        ? null
        : _bubble(context, t, voice);
    return Semantics(
      container: true,
      label: 'You said',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (message.attachments.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: bubble == null ? 0 : 8),
              child: SentAttachments(attachments: message.attachments),
            ),
          ?bubble,
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, HermesTokens t, bool voice) {
    return Semantics(
      container: true,
      child: Align(
        alignment: Alignment.centerRight,
        child: LayoutBuilder(
          builder: (context, box) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * 0.78),
            child: Builder(
              builder: (anchor) => GestureDetector(
                onLongPress: onLongPress == null
                    ? null
                    : () => onLongPress!(anchor),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(Rad.bubble),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (voice)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ExcludeSemantics(
                                  child: WaveGlyph(
                                    color: t.textFaint,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ),
                          TextSpan(text: message.text),
                        ],
                      ),
                      style: t.body,
                    ),
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

String _secs(int s) =>
    s < 60 ? '$s s' : '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';

/// A Hermes reply (chat-rendering-v2 §2.1, §2.4): no bubble, full
/// text-column width. Above the text, one quiet [WorkLine]: what is running
/// while the reply works, then "Worked for 12s", which opens the timeline of
/// thinking and tool steps. An action row once complete.
class AssistantMessage extends StatelessWidget {
  const AssistantMessage({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onDelete,
    this.showActions = true,
    this.steps = const [],
    this.connection,
    this.now,
    this.onLongPress,
    this.onFork,
    this.onWebSearch,
    this.onReport,
  });

  final ChatMessage message;

  /// More › Report reply; null hides it.
  final VoidCallback? onReport;

  /// Retry; null hides it (only the newest reply can be retried).
  final VoidCallback? onRetry;
  final VoidCallback onDelete;

  /// More › Fork to new chat and Search with web; null hides each.
  final VoidCallback? onFork, onWebSearch;
  final bool showActions;

  /// The reply's thinking and tool steps ([ChatController.stepsFor]).
  final List<ReplyStep> steps;

  /// For tests: a fixed clock for step durations.
  final DateTime Function()? now;

  /// A quiet note while the stream is re-established ("Reconnecting…",
  /// "Reply continues in the background"); never an error.
  final String? connection;

  /// Opens the message menu, anchored to the reply; null while streaming.
  /// On the reply's own labelled node, so screen readers name the action.
  final void Function(BuildContext anchor)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final m = message;
    final progress = m.progress;
    final presentation = replyPresentation(m.text, steps);
    final answer = presentation.answer;
    // The glimpse shows while nothing is written yet, while a step runs, or
    // while Hermes reports a wait; otherwise the line settles into its
    // summary (only when there are steps to open).
    final working =
        m.isStreaming &&
        (answer.trim().isEmpty ||
            steps.any((s) => s.running) ||
            progress?.state == ProgressState.info ||
            progress?.state == ProgressState.approval);
    final showLine = working || steps.isNotEmpty;
    final secs = m.meta['seconds'];
    final children = <Widget>[
      if (m.isTask)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              WaveGlyph(color: t.textFaint, size: 14),
              const SizedBox(width: 6),
              Text(
                secs is num
                    ? 'From live voice · ${_secs(secs.round())}'
                    : 'From live voice',
                style: t.label,
              ),
            ],
          ),
        ),
      if (showLine)
        Padding(
          padding: EdgeInsets.only(bottom: answer.isEmpty ? 0 : 4),
          child: WorkLine(
            key: ValueKey('work-${m.id}'),
            steps: steps,
            working: working,
            progress: progress,
            replyStart: m.created,
            now: now,
            replyText: m.text,
          ),
        ),
      if (m.isTask && m.status == MessageStatus.failed && m.text.isEmpty)
        _FailedTask(
          request: '${m.meta['task'] ?? ''}',
          reason: taskFailureText(m),
        )
      else if (answer.isNotEmpty)
        _SelectableAnswer(
          id: m.id,
          // Inside the selection area, so the sidebar swipe sees a drag on
          // text before the selection's own drag recognizer (which would
          // otherwise win on Android).
          child: DrawerSwipeTarget(
            child: MessageMarkdown(text: answer, streaming: m.isStreaming),
          ),
        ),
      // Sources are read once the reply settles, never per stream chunk.
      // With the action row they sit at its end (round 3, reference layout).
      if (!m.isStreaming &&
          answer.isNotEmpty &&
          !(showActions && m.text.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _ReplySources(
            key: ValueKey('sources-${m.id}'),
            answer: answer,
          ),
        ),
      if (m.status == MessageStatus.failed && !m.isTask)
        _InlineError(message: m, onRetry: onRetry),
      // A task that failed after writing part of its answer says so under it.
      if (m.isTask && m.status == MessageStatus.failed && m.text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Task failed · ${taskFailureText(m)}',
            style: t.label.copyWith(color: t.danger),
          ),
        ),
      if (m.status == MessageStatus.stopped ||
          m.status == MessageStatus.interrupted)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          // Interrupted is not an error: the reply was cut off (an old
          // bridge, or the app was in the background).
          child: Text(
            m.status == MessageStatus.stopped ? 'Stopped' : 'Cut off',
            style: t.label,
          ),
        ),
      if (m.isStreaming && connection != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Icon(Icons.sync_rounded, size: 14, color: t.textMuted),
                const SizedBox(width: 6),
                Flexible(child: Text(connection!, style: t.label)),
              ],
            ),
          ),
        ),
      if (showActions && !m.isStreaming && m.text.isNotEmpty)
        _ActionRow(
          message: m,
          onRetry: onRetry,
          onDelete: onDelete,
          onFork: onFork,
          onWebSearch: onWebSearch,
          onReport: onReport,
          steps: steps,
          sources: answer.isEmpty
              ? null
              : _ReplySources(key: ValueKey('sources-${m.id}'), answer: answer),
        ),
    ];
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    final longPress = onLongPress;
    // Explicit child nodes: the answer, credit lines and the Sources header
    // stay their own nodes in reading order instead of merging into the
    // long-press node, which is named only by the assistant. The action sits
    // on that node, not on the gesture detector (which would form its own).
    Widget reply(VoidCallback? onLongPress) => Semantics(
      container: true,
      explicitChildNodes: true,
      label: Brand.assistantName,
      onLongPress: onLongPress,
      onLongPressHint: onLongPress == null ? null : 'Message options',
      child: onLongPress == null
          ? column
          : GestureDetector(
              excludeFromSemantics: true,
              onLongPress: onLongPress,
              child: column,
            ),
    );
    return longPress == null
        ? reply(null)
        : Builder(builder: (anchor) => reply(() => longPress(anchor)));
  }
}

/// Reads a settled reply's sources. Replaced in tests.
@visibleForTesting
List<LiveSite> Function(String answer) replySitesExtractor = extractSites;

/// The sources pill under a settled reply. The parsed sites are kept for the
/// reply's answer text, so rebuilds while another reply streams (or on a
/// theme or text-size change) reuse them; an edit or retry that changes the
/// text reads them again. Only the parsed links are kept, never widgets.
class _ReplySources extends StatefulWidget {
  const _ReplySources({super.key, required this.answer});
  final String answer;

  @override
  State<_ReplySources> createState() => _ReplySourcesState();
}

class _ReplySourcesState extends State<_ReplySources> {
  String? _answer;
  List<LiveSite> _sites = const [];

  List<LiveSite> get _current {
    final answer = widget.answer;
    if (answer != _answer) {
      _answer = answer;
      _sites = hasSourceIndex(answer) ? const [] : replySitesExtractor(answer);
    }
    return _sites;
  }

  @override
  Widget build(BuildContext context) {
    final sites = _current;
    if (sites.isEmpty) return const SizedBox.shrink();
    return LiveSourcesPill(sites: sites);
  }
}

/// Which reply has an active text selection; the shell turns the sidebar
/// swipe off while one does (chat-rendering-v2 §4.3).
abstract final class ThreadSelection {
  static final Map<String, VoidCallback?> _active = {};
  static final active = ValueNotifier<bool>(false);

  /// [clear] drops that reply's selection ([clearAll]).
  static void set(String id, bool selecting, {VoidCallback? clear}) {
    selecting ? _active[id] = clear : _active.remove(id);
    active.value = _active.isNotEmpty;
  }

  /// Clears every reply's selection and its toolbar: a deliberate gesture
  /// elsewhere (swipe up to live from the composer) wins over a selection
  /// a stray long press left behind (round 8).
  static void clearAll() {
    final clears = _active.values.toList();
    _active.clear();
    active.value = false;
    for (final c in clears) {
      c?.call();
    }
    ContextMenuController.removeAny();
  }
}

/// A reply's selectable text; it registers with [ThreadSelection] so the
/// selection can be cleared from outside.
class _SelectableAnswer extends StatefulWidget {
  const _SelectableAnswer({required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<_SelectableAnswer> createState() => _SelectableAnswerState();
}

class _SelectableAnswerState extends State<_SelectableAnswer> {
  final _area = GlobalKey<SelectionAreaState>();

  void _clear() {
    try {
      _area.currentState?.selectableRegion.clearSelection();
    } catch (_) {}
  }

  @override
  void dispose() {
    ThreadSelection.set(widget.id, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    key: _area,
    onSelectionChanged: (c) =>
        ThreadSelection.set(widget.id, c != null, clear: _clear),
    child: widget.child,
  );
}

/// Plain words for a failed reply (spec §5.10).
String failureText(ChatException? e) => switch (e?.kind) {
  ChatErrorKind.usageLimit => 'Usage limit reached. Retry later.',
  ChatErrorKind.loginExpired =>
    'The server’s login has expired. Retry after it is renewed.',
  ChatErrorKind.unauthorized => 'The access key was rejected.',
  ChatErrorKind.network => 'Connection lost. Retry',
  _ => 'Couldn’t get a reply. Retry',
};

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});
  final ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        button: onRetry != null,
        liveRegion: true,
        child: InkWell(
          onTap: onRetry,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: t.danger),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    failureText(message.error),
                    style: t.label.copyWith(color: t.danger),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FailedTask extends StatelessWidget {
  const _FailedTask({required this.request, this.reason});
  final String request;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      container: true,
      label: 'Task, failed',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Rad.card),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: t.danger),
                  const SizedBox(width: 8),
                  Text('Task failed', style: t.label.copyWith(color: t.danger)),
                ],
              ),
              if (reason != null) ...[
                const SizedBox(height: 4),
                Text(reason!, style: t.label),
              ],
              if (request.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  request,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: t.row.hermesWeight(400),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Copy, Read aloud and Share under a finished reply, then More (⋮) and
/// the sources cluster (round 6 B2, after the reference): quiet 18 dp
/// glyphs at reduced opacity. The slots stay 48 dp (the reference packs
/// them tighter; 48 keeps the minimum tap target), the first glyph's ink on
/// the text's left edge. Everything else (Fork, Retry, Search with web,
/// Details, Delete) is in More. Fades in 150 ms after the stream ends,
/// over 200 ms.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.message,
    required this.onRetry,
    required this.onDelete,
    this.onFork,
    this.onWebSearch,
    this.onReport,
    this.steps = const [],
    this.sources,
  });

  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onFork, onWebSearch, onReport;
  final List<ReplyStep> steps;

  /// The sources cluster, shown after More when the reply cites pages.
  final Widget? sources;

  /// Width of one action slot, and the glyph inside it.
  static const slot = 48.0;
  static const glyph = 20.0;

  /// The glyphs' ink: the text's muted colour, nearly at full strength
  /// (round 8: the reference app's row reads clearly).
  static const opacity = 0.92;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final actions = MessageActions.of(context);
    final read = actions?.readAloud;
    final ink = t.textMuted.withValues(alpha: t.textMuted.a * opacity);
    Widget icon(String label, IconData i, VoidCallback? onTap) => IconButton(
      tooltip: label,
      onPressed: onTap,
      icon: Icon(i, size: glyph, color: ink),
      padding: EdgeInsets.zero,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints.tightFor(width: slot, height: 48),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.of(context, const Duration(milliseconds: 350)),
      builder: (context, v, child) => Opacity(
        opacity: const Interval(150 / 350, 1).transform(v),
        child: child,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Transform.translate(
          // The first glyph's ink lines up with the text's left edge.
          offset: const Offset(-(slot - glyph) / 2, 0),
          child: Row(
            children: [
              icon('Copy', Icons.copy_rounded, () => _copy(context)),
              if (read != null)
                ListenableBuilder(
                  listenable: read,
                  builder: (context, _) {
                    if (!read.available) return const SizedBox.shrink();
                    final on = read.reading == message.id;
                    return icon(
                      on ? 'Stop reading' : 'Read aloud',
                      on
                          ? Icons.stop_circle_outlined
                          : Icons.volume_up_outlined,
                      () => read.toggle(message),
                    );
                  },
                ),
              icon(
                'Share',
                // The platform's own share glyph, as the reference shows.
                Theme.of(context).platform == TargetPlatform.iOS ||
                        Theme.of(context).platform == TargetPlatform.macOS
                    ? Icons.ios_share_rounded
                    : Icons.share_outlined,
                () => _share(context),
              ),
              Builder(
                builder: (anchor) => icon(
                  'More',
                  Icons.more_vert_rounded,
                  () => showMessageMenu(
                    anchor,
                    message: message,
                    onRetry: onRetry,
                    onDelete: onDelete,
                    onFork: onFork,
                    onWebSearch: onWebSearch,
                    onReport: onReport,
                    steps: steps,
                    fromActionRow: true,
                  ),
                ),
              ),
              if (sources != null) ...[
                const SizedBox(width: 4),
                Flexible(child: sources!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: plainText(message.text)));
    MessageActions.of(context)?.notify('Copied');
  }

  Future<void> _share(BuildContext context) async {
    final text = plainText(message.text);
    final actions = MessageActions.of(context);
    if (actions != null) {
      await actions.share(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}

/// "Today · 04:00", "Yesterday · 21:15", "3 Nov · 09:02".
String messageTime(DateTime when, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final local = when.toLocal();
  final hm =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = switch (diff) {
    0 => 'Today',
    1 => 'Yesterday',
    _ =>
      '${local.day} ${months[local.month - 1]}'
          '${local.year == n.year ? '' : ' ${local.year}'}',
  };
  return '$date · $hm';
}

/// The message menu (long-press or More, §2.4; grouped in round 6 B3): a
/// time header, then for replies Fork to new chat, Retry (newest reply
/// only) and Search with web; Share (not from the action row, which has
/// it), Copy as markdown, Copy table (when there is one) and Details; and
/// Delete last, in the error colour. The user's own messages get Copy,
/// Share and Delete. Replies also get Report reply (with [onReport]) just
/// above Delete. Details opens [showReplyDetails] (tokens, timing,
/// model, tools); [steps] are the reply's steps when the caller has them,
/// else they are read from `meta`.
Future<void> showMessageMenu(
  BuildContext anchor, {
  required ChatMessage message,
  required VoidCallback? onRetry,
  required VoidCallback onDelete,
  VoidCallback? onFork,
  VoidCallback? onWebSearch,
  VoidCallback? onReport,
  List<ReplyStep>? steps,
  bool fromActionRow = false,
}) async {
  FeedbackScope.haptic(anchor, Haptic.medium);
  final actions = MessageActions.of(anchor);
  final tables = markdownTables(message.text);
  final reply = message.isAssistant;
  final choice = await showPopover<String>(
    anchor: anchor,
    width: 240,
    label: 'Message options',
    align: message.isUser ? PopoverAlign.end : PopoverAlign.start,
    builder: (context) {
      final t = HermesTokens.of(context);
      Widget item(
        String label,
        IconData icon,
        String value, {
        bool destructive = false,
      }) => PopoverItem(
        label: label,
        icon: icon,
        destructive: destructive,
        onTap: () => Navigator.pop(context, value),
      );
      final branch = [
        if (reply && onFork != null)
          item('Fork to new chat', Icons.call_split_rounded, 'fork'),
        if (onRetry != null) item('Retry', Icons.refresh_rounded, 'retry'),
        if (reply && onWebSearch != null)
          item('Search with web', Icons.travel_explore_rounded, 'web'),
      ];
      final copy = [
        if (message.isUser) item('Copy', Icons.copy_rounded, 'copy'),
        if (!fromActionRow) item('Share', Icons.ios_share_rounded, 'share'),
        if (reply) item('Copy as markdown', Icons.code_rounded, 'markdown'),
        if (tables.isNotEmpty)
          item('Copy table', Icons.table_chart_outlined, 'table'),
        if (reply && !message.isStreaming)
          item('Details', Icons.info_outline_rounded, 'details'),
      ];
      final groups = [
        if (branch.isNotEmpty) branch,
        if (copy.isNotEmpty) copy,
        [
          if (reply && onReport != null)
            item('Report reply', Icons.flag_outlined, 'report'),
          item(
            'Delete',
            Icons.delete_outline_rounded,
            'delete',
            destructive: true,
          ),
        ],
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              messageTime(message.created),
              style: t.label.hermesWeight(400),
            ),
          ),
          for (var g = 0; g < groups.length; g++) ...[
            if (g > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Divider(height: 1, thickness: 1, color: t.hairline),
              ),
            ...groups[g],
          ],
        ],
      );
    },
  );
  switch (choice) {
    case 'copy':
      await Clipboard.setData(ClipboardData(text: plainText(message.text)));
      actions?.notify('Copied');
    case 'share':
      final text = plainText(message.text);
      if (actions != null) {
        await actions.share(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
    case 'markdown':
      await Clipboard.setData(ClipboardData(text: message.text));
      actions?.notify('Copied as markdown');
    case 'table':
      await Clipboard.setData(ClipboardData(text: tables.first));
      actions?.notify(
        tables.length == 1 ? 'Table copied' : 'First table copied',
      );
    case 'fork':
      onFork?.call();
    case 'retry':
      onRetry?.call();
    case 'web':
      onWebSearch?.call();
    case 'details':
      if (anchor.mounted) {
        await showReplyDetails(anchor, message, steps: steps);
      }
    case 'report':
      onReport?.call();
    case 'delete':
      onDelete();
  }
}

/// The GFM tables in [md], each as tab-separated values.
List<String> markdownTables(String md) {
  final out = <String>[];
  final lines = md.split('\n');
  final sep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
  var inFence = false;
  for (var i = 0; i + 1 < lines.length; i++) {
    if (RegExp(r'^ {0,3}(```|~~~)').hasMatch(lines[i])) inFence = !inFence;
    if (inFence || !lines[i].contains('|') || !sep.hasMatch(lines[i + 1])) {
      continue;
    }
    final rows = <String>[_cells(lines[i])];
    var j = i + 2;
    for (; j < lines.length && lines[j].contains('|'); j++) {
      if (lines[j].trim().isEmpty) break;
      rows.add(_cells(lines[j]));
    }
    out.add(rows.join('\n'));
    i = j - 1;
  }
  return out;
}

String _cells(String line) {
  var l = line.trim();
  if (l.startsWith('|')) l = l.substring(1);
  if (l.endsWith('|') && !l.endsWith(r'\|')) l = l.substring(0, l.length - 1);
  return l
      .split(RegExp(r'(?<!\\)\|'))
      .map((c) => _inline(c.trim().replaceAll(r'\|', '|')))
      .join('\t');
}

String _inline(String s) => s
    .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'(?<![*\w])\*([^*\n]+)\*(?!\*)'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'!?\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!)
    .replaceAll(RegExp(r'\[\^[^\]]+\]'), '');

/// Plain text for Copy, Share and read-aloud fallbacks: markdown marks,
/// footnote references and definitions, and `hermes-ui` blocks removed; code
/// kept as written.
String plainText(String md) {
  // hermes-ui blocks read as their prompt, labels and values (§3.7).
  md = hermesUiPlainText(md);
  final out = <String>[];
  var fence = '';
  var skip = false;
  for (final line in md.split('\n')) {
    final f = RegExp(r'^ {0,3}(```|~~~)\s*([\w-]*)').firstMatch(line);
    if (f != null) {
      if (fence.isEmpty) {
        fence = f[1]!;
        skip = f[2] == 'hermes-ui';
        continue;
      }
      if (line.trim().startsWith(fence)) {
        fence = '';
        skip = false;
        continue;
      }
    }
    if (fence.isNotEmpty) {
      if (!skip) out.add(line);
      continue;
    }
    if (RegExp(r'^\s*\[\^[^\]]+\]:').hasMatch(line)) continue;
    if (RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$')
        .hasMatch(line)) {
      continue;
    }
    var l = line.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    if (l.trim().startsWith('|')) {
      l = _cells(l).replaceAll('\t', '  ');
    } else {
      l = _inline(l);
    }
    out.add(l);
  }
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
