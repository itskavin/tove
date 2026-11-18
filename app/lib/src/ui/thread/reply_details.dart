import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../common/floating_sheet.dart';
import '../theme/tokens.dart';
import 'message_actions.dart';

/// What the reply's Details sheet shows (round 3, request 2). Read from the
/// message's `meta` and its steps; a field the bridge does not send yet is
/// null and shows "Not available" (bridge-requests.md, round 3 §R3.1).
@immutable
class ReplyDetails {
  const ReplyDetails({
    required this.id,
    required this.created,
    this.model,
    this.effort,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.reasoningTokens,
    this.cachedTokens,
    this.firstToken,
    this.duration,
    this.finished,
    this.finishReason,
    this.tools = const [],
    this.toolCount,
    this.modelCalls,
  });

  /// Reads the bridge's `meta.usage` (API.md "Usage": `model`,
  /// `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`,
  /// `reasoning_tokens`, `model_calls`, `duration_ms`, `ttft_ms`,
  /// `tool_count`, `effort`), older replies' `prompt_tokens` /
  /// `completion_tokens`, and the OpenAI-style `*_details` and
  /// `meta.timing` forms. Tools fall back to the step timeline.
  factory ReplyDetails.of(ChatMessage m, {List<ReplyStep>? steps}) {
    final meta = m.meta;
    int? n(Object? v) => v is num && v >= 0 ? v.round() : null;
    Map<String, dynamic> map(Object? v) =>
        v is Map ? v.cast<String, dynamic>() : const {};
    final usage = map(meta['usage']);
    final timing = map(meta['timing']);
    final input = n(usage['prompt_tokens'] ?? usage['input_tokens']);
    final output = n(usage['completion_tokens'] ?? usage['output_tokens']);
    final reasoning = n(
      usage['reasoning_tokens'] ??
          map(usage['completion_tokens_details'])['reasoning_tokens'] ??
          map(usage['output_tokens_details'])['reasoning_tokens'],
    );
    final cached = n(
      usage['cached_tokens'] ??
          map(usage['prompt_tokens_details'])['cached_tokens'] ??
          map(usage['input_tokens_details'])['cached_tokens'],
    );
    var total = n(usage['total_tokens']);
    if (total == null && input != null && output != null) {
      total = input + output;
    }
    Duration? ms(Object? v) {
      final i = n(v);
      return i == null ? null : Duration(milliseconds: i);
    }

    final finishedMs = n(meta['completed_at'] ?? timing['completed_at']);
    var finished = finishedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(finishedMs);
    var duration = ms(
      usage['duration_ms'] ?? timing['total_ms'] ?? meta['duration_ms'],
    );
    if (duration == null && finished != null && finished.isAfter(m.created)) {
      duration = finished.difference(m.created);
    }
    // The reply's message is created when the request starts.
    if (finished == null && duration != null) {
      finished = m.created.add(duration);
    }

    // Tools: the step timeline, else the older tool list.
    final all = steps ?? stepsFromJson(meta['steps']);
    final names = <String>[];
    int? count;
    final toolSteps = all.where((s) => s.kind == StepKind.tool).toList();
    if (toolSteps.isNotEmpty) {
      count = toolSteps.length;
      for (final s in toolSteps) {
        final name = s.tool?.name ?? '';
        if (name.isNotEmpty) names.add(name);
      }
    } else if (n(usage['tool_count']) != null) {
      count = n(usage['tool_count']);
    } else if (meta['tools'] is List) {
      final list = meta['tools'] as List;
      count = list.length;
      for (final t in list) {
        if (t is Map && t['tool'] is String) names.add(t['tool'] as String);
      }
    } else if (all.isNotEmpty || meta.containsKey('steps')) {
      count = 0;
    }
    if (count != null && names.isEmpty && meta['tools'] is List) {
      for (final t in meta['tools'] as List) {
        if (t is Map && t['tool'] is String) names.add(t['tool'] as String);
      }
    }
    final model = usage['model'] ?? meta['model'];
    final effort = usage['effort'] ?? meta['effort'];
    final reason = meta['finish_reason'];
    return ReplyDetails(
      id: m.id,
      created: m.created,
      model: model is String && model.trim().isNotEmpty ? model.trim() : null,
      effort: effort is String && effort.isNotEmpty ? effort : null,
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      reasoningTokens: reasoning,
      cachedTokens: cached,
      firstToken: ms(
        usage['ttft_ms'] ?? timing['first_token_ms'] ?? meta['first_token_ms'],
      ),
      duration: duration,
      finished: finished,
      finishReason: reason is String && reason.isNotEmpty ? reason : null,
      tools: {...names}.toList(),
      toolCount: count,
      modelCalls: n(usage['model_calls']),
    );
  }

  final String id;
  final DateTime created;
  final String? model;
  final String? effort;
  final int? inputTokens, outputTokens, totalTokens;
  final int? reasoningTokens, cachedTokens;
  final Duration? firstToken, duration;
  final DateTime? finished;
  final String? finishReason;

  /// Distinct tool names, in first-use order.
  final List<String> tools;

  /// Tool calls, or null when the bridge kept no record.
  final int? toolCount;

  /// Model calls in Hermes' tool loop (each re-sends its system prompt).
  final int? modelCalls;
}

/// `12345` → `12,345`.
String groupedNumber(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// `850 ms`, `4.2 s`, `2 min 05 s`.
String shortDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '$ms ms';
  if (ms < 60000) {
    final s = ms / 1000;
    return '${s < 10 ? s.toStringAsFixed(1) : s.round()} s';
  }
  final s = (ms / 1000).round();
  return '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
}

/// `16 Nov 2026, 04:00:12`.
String detailTime(DateTime when) {
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
  final l = when.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.day} ${months[l.month - 1]} ${l.year}, '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

String _effortName(String wire) => switch (wire) {
  'instant' => 'Instant',
  'medium' => 'Medium',
  'high' => 'High',
  _ => wire,
};

String _finishName(String r) => switch (r) {
  'stop' => 'Complete',
  'length' => 'Cut off at the length limit',
  'tool_calls' => 'Ended on a tool call',
  'content_filter' => 'Filtered',
  _ => r,
};

const notAvailable = 'Not available';

/// The reply's Details sheet: model, tokens, timing, tools and ids, in the
/// same floating sheet as Sources.
Future<void> showReplyDetails(
  BuildContext context,
  ChatMessage message, {
  List<ReplyStep>? steps,
}) {
  final details = ReplyDetails.of(message, steps: steps);
  final notify = MessageActions.of(context)?.notify;
  return showFloatingSheet<void>(
    context,
    page: SheetPage(
      title: 'Details',
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: ReplyDetailsView(details: details, onCopied: notify),
      ),
    ),
  );
}

/// The body of the Details sheet (also used by tests and goldens).
class ReplyDetailsView extends StatelessWidget {
  const ReplyDetailsView({super.key, required this.details, this.onCopied});

  final ReplyDetails details;
  final void Function(String text)? onCopied;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final d = details;
    String tokens(int? v) => v == null ? notAvailable : groupedNumber(v);
    String time(Duration? v) => v == null ? notAvailable : shortDuration(v);
    final toolsValue = d.toolCount == null
        ? notAvailable
        : d.toolCount == 0
        ? 'None'
        : '${d.toolCount} ${d.toolCount == 1 ? 'call' : 'calls'}';
    Widget section(String title, List<Widget> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Semantics(header: true, child: Text(title, style: t.section)),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              thickness: 1,
              color: t.hairline,
              indent: 20,
              endIndent: 20,
            ),
          rows[i],
        ],
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section('Model', [
          _DetailRow(label: 'Model', value: d.model ?? notAvailable),
          _DetailRow(
            label: 'Effort',
            value: d.effort == null ? notAvailable : _effortName(d.effort!),
          ),
        ]),
        section('Tokens', [
          _DetailRow(label: 'Input', value: tokens(d.inputTokens)),
          if (d.cachedTokens != null)
            _DetailRow(label: 'Cached input', value: tokens(d.cachedTokens)),
          _DetailRow(label: 'Output', value: tokens(d.outputTokens)),
          _DetailRow(label: 'Reasoning', value: tokens(d.reasoningTokens)),
          _DetailRow(
            label: 'Total',
            value: tokens(d.totalTokens),
            strong: true,
          ),
          if (d.modelCalls != null)
            _DetailRow(label: 'Model calls', value: '${d.modelCalls}'),
        ]),
        section('Timing', [
          _DetailRow(label: 'First token', value: time(d.firstToken)),
          _DetailRow(label: 'Total time', value: time(d.duration)),
          _DetailRow(label: 'Started', value: detailTime(d.created)),
          _DetailRow(
            label: 'Finished',
            value: d.finished == null ? notAvailable : detailTime(d.finished!),
          ),
        ]),
        section('Tools', [
          _DetailRow(label: 'Tools used', value: toolsValue),
          if (d.tools.isNotEmpty)
            _DetailRow(label: 'Names', value: d.tools.join(', ')),
        ]),
        section('Message', [
          if (d.finishReason != null)
            _DetailRow(label: 'Ended', value: _finishName(d.finishReason!)),
          _DetailRow(
            label: 'Message ID',
            value: d.id,
            mono: true,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: d.id));
              onCopied?.call('Message ID copied');
            },
          ),
        ]),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.strong = false,
    this.mono = false,
    this.onCopy,
  });

  final String label;
  final String value;
  final bool strong, mono;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final missing = value == notAvailable;
    final base = t.row.hermesWeight(strong ? 600 : 400);
    final valueStyle = mono
        ? t.code.copyWith(fontSize: t.row.fontSize! * 0.9, height: 1.3)
        : base.copyWith(color: missing ? t.textFaint : t.text);
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      button: onCopy != null,
      onTap: onCopy,
      onTapHint: onCopy == null ? null : 'Copy',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 8, onCopy == null ? 20 : 4, 8),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  label,
                  style: t.row.hermesWeight(400).copyWith(color: t.textMuted),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: valueStyle,
                  maxLines: mono ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onCopy != null)
                IconButton(
                  tooltip: 'Copy',
                  onPressed: onCopy,
                  icon: Icon(Icons.copy_rounded, size: 18, color: t.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
