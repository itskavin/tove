import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../call/models.dart';
import '../../chat/chat.dart';
import '../common/shimmer.dart';
import '../theme/tokens.dart';
import '../thread/follow_scroll.dart';
import '../thread/message_markdown.dart';
import '../thread/messages.dart';
import 'live_content.dart';
import 'live_link_cards.dart';
import 'live_panel.dart';

/// The actual call transcript, typed turns and delegated work in time order.
/// It listens through LiveOverlay; no second microphone or transcript store.
class LiveTranscriptPanel extends StatelessWidget {
  const LiveTranscriptPanel({
    super.key,
    required this.call,
    required this.chat,
    required this.since,
    required this.scroll,
    required this.topInset,
    required this.fadeStart,
    required this.fadeEnd,
    required this.bottomPadding,
    required this.onCollapse,
    this.onOpenSite,
  });

  final CallController call;
  final ChatController chat;
  final DateTime since;
  final FollowScrollController scroll;
  final double topInset, fadeStart, fadeEnd, bottomPadding;
  final VoidCallback onCollapse;
  final ValueChanged<LiveSite>? onOpenSite;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final turns = <({DateTime time, String id, Widget child})>[];
    for (final e in call.transcript) {
      if (e.created.isBefore(since) || e.text.trim().isEmpty) continue;
      final user = e.speaker == Speaker.user;
      turns.add((
        time: e.created,
        id: 'spoken-${e.id}',
        child: user
            ? Align(
                alignment: Alignment.centerRight,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 300),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Semantics(
                    label: 'You said',
                    child: Text(e.text, style: t.body),
                  ),
                ),
              )
            : MessageMarkdown(text: e.text, streaming: e.live),
      ));
    }
    for (final m in chat.messages) {
      if (m.created.isBefore(since) || m.source != MessageSource.text) continue;
      turns.add((
        time: m.created,
        id: 'typed-${m.id}',
        child: m.isAssistant
            ? AssistantMessage(
                message: m,
                steps: chat.stepsFor(m),
                onRetry: null,
                onDelete: () {},
                showActions: false,
              )
            : UserBubble(message: m),
      ));
    }
    for (final task in call.tasks) {
      if (task.created.isBefore(since)) continue;
      final c = liveContentById('task-${task.itemId}', call: call, chat: chat);
      // A finished task with no answer has no content: say so plainly.
      final muted = c == null || c.failed || c.continuesInChat;
      final text = c?.text ?? task.detail ?? 'Hermes returned no answer';
      turns.add((
        time: task.created,
        id: 'task-${task.itemId}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              task.text,
              style: t.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            if (task.active)
              ShimmerText(
                'Working on it${task.seconds > 0 ? ' · ${task.seconds}s' : ''}',
              )
            else if (muted)
              Text(text, style: t.body.copyWith(color: t.textMuted))
            else
              MessageMarkdown(text: text),
            if (!muted && c.sites.isNotEmpty) ...[
              const SizedBox(height: 16),
              LiveSiteCards(sites: c.sites, onOpen: onOpenSite),
            ],
          ],
        ),
      ));
    }
    turns.sort((a, b) => a.time.compareTo(b.time));
    return LivePanelFade(
      fadeStart: fadeStart,
      fadeEnd: fadeEnd,
      child: SingleChildScrollView(
        key: const ValueKey('live-transcript-scroll'),
        controller: scroll,
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, bottomPadding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Sz.contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Live conversation', style: t.label)),
                    IconButton(
                      onPressed: onCollapse,
                      tooltip: 'Hide conversation',
                      icon: const Icon(Icons.expand_more_rounded),
                    ),
                  ],
                ),
                if (turns.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text(
                      'Your live conversation will appear here as you speak.',
                      style: t.body.copyWith(color: t.textMuted),
                    ),
                  ),
                for (final turn in turns)
                  Padding(
                    key: ValueKey(turn.id),
                    padding: const EdgeInsets.only(top: 20, bottom: 4),
                    child: turn.child,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
