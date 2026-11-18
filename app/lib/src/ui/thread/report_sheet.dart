import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../common/floating_sheet.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';
import 'message_actions.dart';

/// More › Report reply (a bad or harmful answer): pick a reason,
/// add an optional note, and choose whether to hide the reply here. The
/// report goes only to the user's own server ([submitReport]).
Future<ReplyReport?> showReportSheet(BuildContext context) =>
    showFloatingSheet<ReplyReport>(
      context,
      page: SheetPage(
        title: 'Report reply',
        subtitle: 'Sent to your server’s owner, not to anyone else',
        builder: (_) => const ReportForm(),
      ),
    );

/// Shows the sheet for [message] and sends the report through [api].
Future<void> reportReply(
  BuildContext context,
  ChatApi api,
  ChatMessage message, {
  HiddenReplies? hidden,
}) async {
  final actions = MessageActions.of(context);
  final report = await showReportSheet(context);
  if (report == null) return;
  final r = await submitReport(
    api,
    messageId: message.id,
    conversationId: message.conversationId.isEmpty
        ? null
        : message.conversationId,
    report: report,
    hidden: hidden,
  );
  actions?.notify(switch (r) {
    (sent: true, hidden: true) => 'Reported and hidden',
    (sent: true, hidden: false) => 'Reported. Thanks',
    (sent: false, hidden: true) => 'Hidden. Your server didn’t take the report',
    (sent: false, hidden: false) => 'Your server didn’t take the report',
  });
}

/// The sheet's body: reasons, note, hide switch, Send.
class ReportForm extends StatefulWidget {
  const ReportForm({super.key});

  @override
  State<ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<ReportForm> {
  ReportReason? _reason;
  bool _hide = true;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final reason = _reason;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: [
        const SectionHeader(
          'What’s wrong with it?',
          padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
        ),
        GroupCard(
          children: [
            for (final r in ReportReason.values)
              GroupRow(
                key: ValueKey('report-${r.wire}'),
                label: r.label,
                subtitle: r.hint,
                selected: _reason == r,
                onTap: () => setState(() => _reason = r),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextField(
            key: const ValueKey('report-note'),
            controller: _note,
            minLines: 2,
            maxLines: 5,
            maxLength: ReplyReport.noteChars,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        GroupCard(
          children: [
            SwitchRow(
              key: const ValueKey('report-hide'),
              label: 'Hide this reply',
              icon: Icons.visibility_off_outlined,
              subtitle: 'On this device. You can show it again.',
              value: _hide,
              onChanged: (v) => setState(() => _hide = v),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton(
            key: const ValueKey('report-send'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: reason == null
                ? null
                : () => Navigator.pop(
                    context,
                    ReplyReport(reason: reason, note: _note.text, hide: _hide),
                  ),
            child: const Text('Send report'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          child: Text(
            'The report and a copy of the reply are saved on your server. '
            'If the reply came from an AI provider your server uses, its '
            'owner can pass the report on.',
            style: t.label.copyWith(color: t.textMuted, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// What a hidden reply shows instead of its text.
class HiddenReplyNotice extends StatelessWidget {
  const HiddenReplyNotice({super.key, required this.onShow});
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      container: true,
      child: Row(
        children: [
          Icon(Icons.visibility_off_outlined, size: 18, color: t.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You reported and hid this reply.',
              style: t.label.copyWith(color: t.textMuted),
            ),
          ),
          TextButton(
            key: const ValueKey('hidden-reply-show'),
            onPressed: onShow,
            child: const Text('Show'),
          ),
        ],
      ),
    );
  }
}

/// Unhides [id] (the notice's Show button).
void showHiddenReply(String id, {HiddenReplies? hidden}) =>
    unawaited((hidden ?? HiddenReplies.instance).unhide(id));
