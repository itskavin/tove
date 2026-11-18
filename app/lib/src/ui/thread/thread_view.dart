import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../interactive/interactive.dart';
import '../feedback.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'empty_thread.dart';
import 'follow_scroll.dart';
import 'message_actions.dart';
import 'messages.dart';
import 'report_sheet.dart';
import 'starter_prompts.dart';
import '../../brand.dart';

/// The thread in text mode (chat-rendering-v2 §2): newest at the bottom,
/// 16 dp gutters, a 680 dp reading measure and a scroll-to-latest button.
///
/// A message the user sends comes up to sit just under the app bar, with the
/// reply growing below it; the turn (that message and what follows) is at
/// least a viewport tall, so a short reply still leaves the message on top.
/// The stream does not scroll the view while that turn is shown, until the
/// user goes to the latest text themselves. A chat that is opened shows its
/// newest messages and follows the stream while the user is within 160 dp of
/// the end.
class ThreadView extends StatefulWidget {
  const ThreadView({
    super.key,
    required this.chat,
    required this.scroll,
    required this.topInset,
    required this.bottomInset,
    required this.onSuggestion,
    this.startersActive = true,
    this.liveAvailable = true,
    this.onFocusComposer,
    this.prompts,
    this.endGap = defaultEndGap,
    this.centredComposer,
  });

  final ChatController chat;
  final FollowScrollController scroll;

  /// Space for the app bar above and the composer below.
  final double topInset;
  final double bottomInset;
  final ValueChanged<String> onSuggestion;

  /// False pauses the empty chat's drifting starter rows (the chat is
  /// covered by a panel or live mode).
  final bool startersActive;
  final bool liveAvailable;

  /// hermes-ui "Other…" chips focus the composer.
  final VoidCallback? onFocusComposer;

  /// The empty chat's suggestions (the shell picks a fresh set for every
  /// new chat); null shows the first [suggestions].
  final List<StarterPrompt>? prompts;

  /// Room left between the end of the thread (the last reply's action row,
  /// or the streaming text) and [bottomInset], at rest, while streaming and
  /// with the keyboard open.
  final double endGap;
  static const defaultEndGap = 16.0;

  /// Wide layouts: the composer's pill rect while it sits centred on an
  /// empty chat (the greeting goes above it, the suggestions below).
  final Rect? centredComposer;

  /// Space between the app bar and the first message at rest; the app-bar
  /// scrim fades out over it.
  static const underBar = 16.0;

  /// Text gutter and reading measure (chat-rendering-v2 §2.1).
  static const gutter = 16.0;
  static const measure = 680.0;

  static final suggestions = [for (final p in starterPool.take(4)) p.text];

  @override
  State<ThreadView> createState() => ThreadViewState();
}

class ThreadViewState extends State<ThreadView> {
  /// Message ids already on screen; only new ones play the entry motion.
  final Set<String> _seen = {};
  String? _threadKey;
  String? _streamingId;
  int _importBudget = 0;
  int _importIndex = 0;

  /// Scroll-to-latest (§2.3): shown when far from the end, with a dot when
  /// new text arrived below the viewport.
  bool _showJump = false;
  bool _openAtEnd = true;

  /// Jumps to the end after layout, a few frames in a row: the lazy list's
  /// extent grows as items lay out. Once there, following keeps it there.
  void _settleAtEnd(int frames) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.scroll;
      if (c.hasClients && c.position.hasContentDimensions) {
        c.jumpTo(c.position.maxScrollExtent);
      }
      if (frames > 1) _settleAtEnd(frames - 1);
    });
  }

  bool _newBelow = false;
  int _lastLength = 0;

  /// The turn the user sent last in this thread ([ChatMessage.clientId],
  /// kept across the optimistic → server id swap, or the id).
  String? _anchorClient;
  String? _anchorId;

  /// Gap above the anchored message; it sits this much below the turn's top.
  double _anchorGap = 0;

  /// Programmatic reveal still pending (a user drag cancels it).
  int _revealToken = 0;
  final _tailKey = GlobalKey();
  final _tailContentKey = GlobalKey();

  double get _topPad => widget.topInset + ThreadView.underBar;
  double get _bottomPad => widget.bottomInset + widget.endGap;

  bool get _anchored => _anchorClient != null;

  /// Starts a new turn at [m]: it is brought under the app bar after layout,
  /// and the stream stops following until the user asks for the latest.
  void _anchorTo(ChatMessage m) {
    _anchorClient = m.clientId ?? m.id;
    _anchorId = m.id;
    _openAtEnd = false;
    widget.scroll.enabled = false;
    _reveal(++_revealToken, 4, animate: true);
  }

  void _clearAnchor() {
    if (_anchorClient == null) return;
    _anchorClient = null;
    _anchorId = null;
    _revealToken++;
    widget.scroll.enabled = true;
  }

  /// The scroll offset that puts the anchored message's top [_topPad] below
  /// the viewport's top, or null before the turn is laid out.
  double? _anchorOffset() {
    final ro = _tailKey.currentContext?.findRenderObject();
    final c = widget.scroll;
    if (ro == null || !ro.attached || !c.hasClients) return null;
    final p = c.position;
    if (!p.hasContentDimensions) return null;
    final reveal = RenderAbstractViewport.of(ro).getOffsetToReveal(ro, 0);
    return (reveal.offset + _anchorGap - _topPad).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
  }

  /// Moves the anchored turn into place after layout: one animation (or a
  /// jump with reduced motion or from far away), then checks over a few
  /// frames, since the lazy list's offsets settle as items lay out.
  void _reveal(int token, int frames, {bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || token != _revealToken) return;
      final target = _anchorOffset();
      final c = widget.scroll;
      if (target != null && (c.position.pixels - target).abs() > 0.5) {
        final p = c.position;
        final far = (p.pixels - target).abs() > 3 * p.viewportDimension;
        if (animate && !far && !Motion.reduced(context)) {
          await p.animateTo(
            target,
            duration: const Duration(milliseconds: 300),
            curve: Motion.standard,
          );
        } else {
          p.jumpTo(target);
        }
      }
      if (mounted && token == _revealToken && frames > 1) {
        _reveal(token, frames - 1);
      }
    });
  }

  /// The anchored turn is taller than its minimum: the reply runs past the
  /// viewport.
  bool get _turnOverflows {
    final box = _tailContentKey.currentContext?.findRenderObject();
    final outer = _tailKey.currentContext?.findRenderObject();
    if (box is! RenderBox || outer is! RenderBox) return false;
    if (!box.hasSize || !outer.hasSize) return false;
    return box.size.height >= outer.size.height - 0.5;
  }

  /// A user scroll cancels a pending reveal; ending one at the latest text of
  /// a long anchored reply lets the stream follow again (as the jump does).
  bool _onUserScroll(UserScrollNotification n) {
    if (n.depth != 0 || !_anchored) return false;
    if (n.direction != ScrollDirection.idle) {
      _revealToken++;
      return false;
    }
    final m = n.metrics;
    if (m.maxScrollExtent - m.pixels <= 8 && _turnOverflows) {
      widget.scroll.enabled = true;
    }
    return false;
  }

  /// The next [count] new messages enter staggered by 30 ms (transcript
  /// import after a call, §6.3); at most 6 animate.
  void staggerNext(int count) {
    _importBudget = count.clamp(0, 6);
    _importIndex = 0;
  }

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChat);
    widget.scroll.addListener(_onScroll);
    // Replies hidden after a report (this device only).
    unawaited(HiddenReplies.instance.load());
    _remember(initial: true);
    if (!widget.chat.loading && widget.chat.messages.isNotEmpty) {
      _openAtEnd = false;
      _settleAtEnd(3);
    }
  }

  void _onScroll() => _updateJump();

  void _updateJump() {
    final c = widget.scroll;
    if (!c.hasClients || !c.position.hasContentDimensions) return;
    final p = c.position;
    final away = p.maxScrollExtent - p.pixels;
    final streaming = widget.chat.streaming;
    final show =
        away > p.viewportDimension || (streaming && away > c.threshold);
    final newBelow = show && _newBelow;
    if (show != _showJump || newBelow != _newBelow) {
      setState(() {
        _showJump = show;
        _newBelow = newBelow;
      });
    }
  }

  Future<void> _jump() async {
    final c = widget.scroll;
    if (!c.hasClients) return;
    final p = c.position;
    final far = p.maxScrollExtent - p.pixels > 3 * p.viewportDimension;
    setState(() => _newBelow = false);
    _revealToken++;
    // The user asked for the latest: the stream follows again.
    widget.scroll.enabled = true;
    await c.toEnd(
      duration: far || Motion.reduced(context)
          ? null
          : const Duration(milliseconds: 300),
      curve: Motion.standard,
    );
    // The lazy list's extent grows while it lays out new items: finish at
    // the real end.
    if (mounted) _settleAtEnd(3);
  }

  @override
  void didUpdateWidget(ThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat != widget.chat) {
      oldWidget.chat.removeListener(_onChat);
      widget.chat.addListener(_onChat);
    }
    if (oldWidget.scroll != widget.scroll) {
      oldWidget.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChat);
    widget.scroll.removeListener(_onScroll);
    widget.scroll.enabled = true;
    super.dispose();
  }

  void _remember({bool initial = false}) {
    final key = widget.chat.currentConversationId ?? '';
    if (initial || key != _threadKey || widget.chat.loading) {
      _threadKey = key;
      _seen
        ..clear()
        ..addAll(widget.chat.messages.map((m) => m.id));
    }
  }

  void _onChat() {
    final chat = widget.chat;
    final key = chat.currentConversationId ?? '';
    // Opening another chat (or a load finishing) shows it without motion.
    if (key != _threadKey && _threadKey != '' || chat.loading) {
      _remember(initial: true);
    }
    // The first reply to a new chat gives it an id: the same thread.
    final continued =
        _threadKey == '' && key != '' && _anchored && !chat.loading;
    // A chat that was opened (or reloaded) shows its newest messages, with
    // no turn held under the app bar.
    if (!continued && (key != _threadKey || chat.loading)) {
      _openAtEnd = true;
      _clearAnchor();
    }
    if (chat.messages.isEmpty) _clearAnchor();
    // A message sent here (not one restored with the chat) starts a turn.
    if (!chat.loading) {
      for (final m in chat.messages.reversed) {
        if (!m.isUser) continue;
        if (m.status == MessageStatus.sending &&
            !_seen.contains(m.id) &&
            (m.clientId ?? m.id) != _anchorClient) {
          _anchorTo(m);
        }
        break;
      }
    }
    if (_openAtEnd && !chat.loading && chat.messages.isNotEmpty) {
      _openAtEnd = false;
      _settleAtEnd(3);
    }
    _threadKey = key;
    // One announcement when a reply completes, never per token (§8.4).
    final s = chat.streamingMessage?.id;
    if (_streamingId != null && s == null) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        '${Brand.assistantName} replied',
        Directionality.of(context),
      );
    }
    _streamingId = s;
    final len = chat.streamingMessage?.text.length ?? 0;
    if (s != null && len > _lastLength && !widget.scroll.atEnd) {
      _newBelow = true;
    }
    _lastLength = len;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateJump();
    });
  }

  bool _animateFor(ChatMessage m) {
    if (_seen.contains(m.id)) return false;
    _seen.add(m.id);
    // Optimistic ids are replaced by server ids; do not replay.
    return m.isUser && m.status == MessageStatus.sending ||
        _importBudget > 0 && _importIndex < _importBudget;
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final messages = chat.messages;
    if (messages.isEmpty && !chat.loading) {
      return EmptyThread(
        topInset: widget.topInset,
        bottomInset: widget.bottomInset,
        chatEnabled: chat.textChatAvailable,
        prompts:
            widget.prompts ??
            starterPool.take(StarterPrompts.marqueeCount).toList(),
        onSuggestion: widget.onSuggestion,
        centredComposer: widget.centredComposer,
        active: widget.startersActive,
      );
    }
    // Only the newest reply can be retried (§2.4, API.md `retry`).
    final lastAssistant = messages.lastIndexWhere(
      (m) => m.isAssistant && !m.isTask,
    );
    // The anchored turn: the message the user sent last and what follows.
    var anchor = -1;
    if (_anchorClient != null) {
      anchor = messages.lastIndexWhere(
        (m) =>
            m.isUser &&
            (m.clientId != null && m.clientId == _anchorClient ||
                m.id == _anchorId),
      );
      if (anchor >= 0) _anchorId = messages[anchor].id;
    }
    final headCount = anchor < 0 ? messages.length : anchor;
    if (anchor >= 0) _anchorGap = _gapBefore(messages, anchor);
    Widget item(BuildContext context, int i) =>
        _item(context, messages, i, lastAssistant);
    final list = NotificationListener<UserScrollNotification>(
      onNotification: _onUserScroll,
      child: Scrollbar(
        controller: widget.scroll,
        child: LayoutBuilder(
          builder: (context, box) => CustomScrollView(
            controller: widget.scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(padding: EdgeInsets.only(top: _topPad)),
              SliverList.builder(
                itemCount: headCount + (chat.hasOlder ? 1 : 0),
                itemBuilder: (context, i) {
                  if (chat.hasOlder) {
                    if (i == 0) return _OlderLoader(chat: chat);
                    i -= 1;
                  }
                  return item(context, i);
                },
              ),
              if (anchor >= 0)
                SliverToBoxAdapter(
                  // At least the room between the bars (plus the gap above
                  // the message), so the message can sit on top however
                  // short the reply is. It changes with the insets, not
                  // with the content, so nothing moves when it is reached.
                  child: ConstrainedBox(
                    key: _tailKey,
                    constraints: BoxConstraints(
                      minHeight:
                          (box.maxHeight - _topPad - _bottomPad + _anchorGap)
                              .clamp(0.0, double.infinity),
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Column(
                        key: _tailContentKey,
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = anchor; i < messages.length; i++)
                            item(context, i),
                        ],
                      ),
                    ),
                  ),
                ),
              SliverPadding(padding: EdgeInsets.only(bottom: _bottomPad)),
            ],
          ),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: list),
        // Its bottom sits 24 dp above the composer's top (§2.3); the inset
        // already includes 8 dp below the composer.
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.bottomInset - 8 + 24,
          child: Center(
            child: _JumpButton(
              visible: _showJump,
              dot: _newBelow && chat.streaming,
              onTap: _jump,
            ),
          ),
        ),
      ],
    );
  }
}

/// [messages][i] is a spoken assistant turn directly followed by another
/// assistant message.
bool _continuesSpoken(List<ChatMessage> messages, int i) =>
    messages[i].isAssistant &&
    messages[i].isVoice &&
    i + 1 < messages.length &&
    messages[i + 1].isAssistant;

extension on ThreadViewState {
  /// User → reply 24 dp; a reply's action row → the next user bubble 20 dp
  /// (§2.1).
  double _gapBefore(List<ChatMessage> messages, int i) {
    final m = messages[i];
    final prev = i > 0 ? messages[i - 1] : null;
    return prev == null
        ? 0.0
        : prev.role == m.role
        ? Sp.sameSpeaker
        : m.isUser
        ? 20.0
        : Sp.betweenSpeakers;
  }

  Widget _item(
    BuildContext context,
    List<ChatMessage> messages,
    int i,
    int lastAssistant,
  ) {
    final chat = widget.chat;
    final m = messages[i];
    final gap = _gapBefore(messages, i);
    final animate = _animateFor(m);
    final delay = animate && _importBudget > 0
        ? Duration(milliseconds: 30 * _importIndex++)
        : Duration.zero;
    if (_importIndex >= _importBudget) _importBudget = 0;
    // An assistant message from /api/notify answers no user message: a
    // retry would regenerate (and delete) it.
    final retry = i == lastAssistant && !m.isNotify && chat.canSend
        ? () => chat.retry(m)
        : null;
    // Fork and Search with web start a new turn, so they need a free chat.
    final fork = !m.isNotify && chat.canSend ? () => chat.fork(m) : null;
    final question = m.isUser ? null : chat.questionFor(m);
    final web =
        chat.capabilities.webSearch &&
            chat.canSend &&
            (question?.text.trim().isNotEmpty ?? false)
        ? () => chat.searchWeb(m)
        : null;
    // More › Report reply: finished replies that exist on the bridge.
    final report = m.isLocal || m.isStreaming
        ? null
        : () => unawaited(reportReply(context, chat.api, m));
    Widget child = m.isUser
        ? UserBubble(
            message: m,
            onLongPress: (anchor) => showMessageMenu(
              anchor,
              message: m,
              onRetry: null,
              onDelete: () => chat.deleteMessage(m.id),
            ),
          )
        : _withUi(
            context,
            messages,
            i,
            AssistantMessage(
              message: m,
              onRetry: retry,
              onDelete: () => chat.deleteMessage(m.id),
              onFork: fork,
              onWebSearch: web,
              onReport: report,
              // A spoken turn that Hermes followed straight away with more
              // (the rest of its answer, or a task result) is part of one
              // reply: only the last of the run gets the action row. Its
              // own menu stays on long press.
              showActions: !_continuesSpoken(messages, i),
              steps: chat.stepsFor(m),
              connection: m.isStreaming ? _connection(chat) : null,
              onLongPress: m.isStreaming
                  ? null
                  : (anchor) => showMessageMenu(
                      anchor,
                      message: m,
                      onRetry: retry,
                      onDelete: () => chat.deleteMessage(m.id),
                      onFork: fork,
                      onWebSearch: web,
                      onReport: report,
                    ),
            ),
          );
    if (!m.isUser) {
      final shown = child;
      child = ListenableBuilder(
        listenable: HiddenReplies.instance,
        builder: (context, _) => HiddenReplies.instance.isHidden(m.id)
            ? HiddenReplyNotice(
                key: ValueKey('hidden-${m.id}'),
                onShow: () => showHiddenReply(m.id),
              )
            : shown,
      );
    }
    child = MessageEntry(
      key: ValueKey('entry-${m.clientId ?? m.id}'),
      animate: animate,
      delay: delay,
      alignment: m.isUser ? Alignment.bottomRight : Alignment.bottomLeft,
      child: child,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: ThreadView.measure + 2 * ThreadView.gutter,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            ThreadView.gutter,
            gap,
            ThreadView.gutter,
            0,
          ),
          child: RepaintBoundary(child: child),
        ),
      ),
    );
  }

  /// hermes-ui wiring for one reply (chat-rendering-v2 §3): `send` posts a
  /// visible message, `copy` confirms with a toast, and blocks lock once a
  /// later user message exists. The newest finished reply also shows its
  /// follow-up suggestions under the action row.
  Widget _withUi(
    BuildContext context,
    List<ChatMessage> messages,
    int i,
    Widget reply,
  ) {
    final chat = widget.chat;
    final m = messages[i];
    String? next;
    for (var j = i + 1; j < messages.length; j++) {
      if (messages[j].isUser) {
        next = messages[j].text;
        break;
      }
    }
    final actions = MessageActions.of(context);
    // Follow-ups only under the newest finished reply; they go away as soon
    // as the user sends anything.
    final extras = i == messages.length - 1
        ? HermesReplyExtras.maybe(
            m.text,
            streaming: m.isStreaming,
            onSend: chat.canSend ? widget.onSuggestion : null,
          )
        : null;
    return HermesUiScope(
      onSend: widget.onSuggestion,
      onCopy: (text) {
        Clipboard.setData(ClipboardData(text: text));
        actions?.notify('Copied');
      },
      onFocusComposer: widget.onFocusComposer,
      onSelectionHaptic: () => FeedbackScope.haptic(context, Haptic.selection),
      nextUserMessage: next,
      enabled: chat.canSend,
      // Checklist ticks are kept per message.
      stateKey: m.id,
      child: extras == null
          ? reply
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [reply, extras],
            ),
    );
  }

  /// The quiet connection note under a streaming reply.
  String? _connection(ChatController chat) {
    if (!chat.reconnecting) return null;
    final foreground = chat.replies.foreground;
    return foreground ? 'Reconnecting…' : 'Reply continues in the background';
  }
}

class _OlderLoader extends StatefulWidget {
  const _OlderLoader({required this.chat});
  final ChatController chat;

  @override
  State<_OlderLoader> createState() => _OlderLoaderState();
}

class _OlderLoaderState extends State<_OlderLoader> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.chat.loadingOlder) widget.chat.loadOlder();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 48,
    child: Center(
      child: SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// The 44 dp scroll-to-latest circle (§2.3): fade and scale 0.9 → 1 over 150
/// ms in, 120 ms out; a 6 dp accent dot while new text arrives below.
class _JumpButton extends StatelessWidget {
  const _JumpButton({
    required this.visible,
    required this.dot,
    required this.onTap,
  });

  final bool visible;
  final bool dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Motion.of(
          context,
          Duration(milliseconds: visible ? 150 : 120),
        ),
        child: AnimatedScale(
          scale: visible ? 1 : 0.9,
          duration: Motion.of(
            context,
            Duration(milliseconds: visible ? 150 : 120),
          ),
          curve: Curves.easeOut,
          child: ExcludeSemantics(
            excluding: !visible,
            child: Semantics(
              container: true,
              button: true,
              label: 'Scroll to latest',
              excludeSemantics: true,
              onTap: onTap,
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Material(
                        color: t.surface,
                        shape: CircleBorder(
                          side: BorderSide(color: t.hairline),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: onTap,
                          child: SizedBox.square(
                            dimension: 44,
                            child: Icon(
                              Icons.arrow_downward_rounded,
                              size: 22,
                              color: t.text,
                            ),
                          ),
                        ),
                      ),
                      if (dot)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: t.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
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
