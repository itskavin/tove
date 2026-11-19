// The Quiz component: one question at a time, big answer buttons, progress,
// Back, and auto-advance, all on the phone (no model round trip per
// question). The answers are kept like checklist ticks (ChecklistStore,
// synced through the bridge's settings), so leaving and returning keeps
// them. At the end ONE visible message sends every answer, for the next
// turn to interpret. Practice questions with an `answer` show right or
// wrong and the explanation before moving on.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../interactive/checklist_store.dart'
    show ChecklistScope, ChecklistStore;
import '../interactive/scope.dart';
import '../markdown/markdown_style.dart';
import '../theme/tokens.dart';

@immutable
class OuiQuestion {
  const OuiQuestion({
    required this.text,
    required this.options,
    this.answer,
    this.explain,
  });
  final String text;
  final List<String> options;

  /// Index of the correct option (practice quizzes), or null.
  final int? answer;
  final String? explain;
}

/// The message the quiz sends: every answer, compact and readable.
String quizMessage(String title, List<OuiQuestion> qs, Map<int, int> picks) {
  final practice = qs.any((q) => q.answer != null);
  if (practice) {
    var right = 0;
    final missed = <String>[];
    for (final (i, q) in qs.indexed) {
      final p = picks[i];
      if (p != null && p == q.answer) {
        right++;
      } else if (q.answer != null) {
        missed.add(
          'Q${i + 1} (I said ${p == null ? '–' : q.options[p]}; '
          'answer ${q.options[q.answer!]})',
        );
      }
    }
    final base = '$title: $right of ${qs.length} correct';
    return missed.isEmpty ? base : '$base. Missed: ${missed.join('; ')}';
  }
  final parts = [
    for (final (i, q) in qs.indexed)
      '${i + 1} ${picks[i] == null ? '–' : q.options[picks[i]!]}',
  ];
  return '$title answers: ${parts.join('; ')}';
}

class OuiQuizView extends StatefulWidget {
  const OuiQuizView({
    super.key,
    required this.id,
    required this.title,
    required this.questions,
    required this.style,
    this.source,
    this.note,
  });

  /// Stable within the message (the statement id), for saved answers.
  final String id;
  final String title;
  final List<OuiQuestion> questions;
  final String? source, note;
  final MarkdownStyle style;

  /// Longest message the quiz sends (longer than a button's).
  static const maxMessage = 1500;

  @override
  State<OuiQuizView> createState() => _OuiQuizViewState();
}

class _OuiQuizViewState extends State<OuiQuizView> {
  ChecklistStore? _store;
  String? _key;
  Map<int, int>? _local;
  int? _page;
  bool _sentHere = false;
  Timer? _advance;

  List<OuiQuestion> get qs => widget.questions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = ChecklistScope.maybeOf(context);
    final msg = HermesUiScope.maybeOf(context)?.stateKey;
    _key = msg == null ? null : '$msg#quiz.${widget.id}';
  }

  @override
  void dispose() {
    _advance?.cancel();
    super.dispose();
  }

  /// Saved answers: "q.o" entries, plus "s" once sent.
  Set<String> get _saved {
    final key = _key;
    return (key == null ? null : _store?.doneFor(key)) ?? const {};
  }

  Map<int, int> get _picks {
    if (_local != null) return _local!;
    final out = <int, int>{};
    for (final e in _saved) {
      final m = RegExp(r'^(\d+)\.(\d+)$').firstMatch(e);
      if (m == null) continue;
      final q = int.parse(m[1]!), o = int.parse(m[2]!);
      if (q < qs.length && o < qs[q].options.length) out[q] = o;
    }
    return out;
  }

  bool get _sent => _sentHere || _saved.contains('s');

  void _save(Map<int, int> picks, {bool sent = false}) {
    final key = _key;
    if (key == null) return;
    _store?.setDone(key, {
      for (final e in picks.entries) '${e.key}.${e.value}',
      if (sent || _sent) 's',
    });
  }

  int get _current {
    final picks = _picks;
    final first = List.generate(
      qs.length,
      (i) => i,
    ).where((i) => !picks.containsKey(i)).firstOrNull;
    return (_page ?? first ?? qs.length).clamp(0, qs.length);
  }

  void _pick(int q, int o) {
    final h = UiActionHandler.of(context);
    h.selectionHaptic();
    final picks = {..._picks, q: o};
    setState(() {
      _local = picks;
      _page = q; // stay here: practice shows feedback, others advance below
    });
    _save(picks);
    _advance?.cancel();
    if (qs[q].answer != null) return; // practice: read the feedback first
    _advance = Timer(
      Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 260),
      () {
        if (mounted) setState(() => _page = q + 1);
      },
    );
  }

  void _send(UiActionHandler h) {
    var text = quizMessage(
      widget.title,
      qs,
      _picks,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > OuiQuizView.maxMessage) {
      text = text.substring(0, OuiQuizView.maxMessage);
    }
    if (!h.canSend || _sent) return;
    h.send(text);
    setState(() => _sentHere = true);
    _save(_picks, sent: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final t = HermesTokens.of(context);
    final h = UiActionHandler.of(context);
    final picks = _picks;
    final n = qs.length;
    final cur = _current;
    final done = picks.length;
    final pct = n == 0 ? 0 : (done * 100 / n).round();
    final locked = _sent || h.nextUserMessage != null;

    final header = <Widget>[
      Text(widget.title, style: s.title),
      const SizedBox(height: 10),
      Semantics(
        liveRegion: true,
        label: cur < n
            ? 'Question ${cur + 1} of $n, $pct percent complete'
            : 'All $n answered',
        excludeSemantics: true,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text(
              cur < n ? 'Question ${cur + 1} of $n' : 'All $n answered',
              style: s.caption.copyWith(
                color: s.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '$pct% complete',
              style: s.caption.copyWith(color: s.textMuted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: n == 0 ? 0 : done / n,
          minHeight: 6,
          color: t.accent,
          backgroundColor: s.hairline,
        ),
      ),
      const SizedBox(height: 16),
    ];

    final body = cur < n
        ? _question(cur, picks[cur], locked, s, t)
        : _summary(picks, locked, h, s, t);

    final footer = [
      if (widget.note != null || widget.source != null) ...[
        const SizedBox(height: 12),
        Divider(height: 1, thickness: 1, color: s.hairline),
        const SizedBox(height: 8),
        if (widget.note != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: s.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.note!,
                  style: s.caption.copyWith(color: s.textMuted),
                ),
              ),
            ],
          ),
        if (widget.source != null)
          Padding(
            padding: EdgeInsets.only(top: widget.note == null ? 0 : 4),
            child: Text(
              'Source: ${widget.source}',
              style: s.caption.copyWith(color: s.textMuted),
            ),
          ),
      ],
    ];

    return Container(
      key: const ValueKey('oui-quiz'),
      decoration: BoxDecoration(
        border: Border.all(color: s.outline),
        borderRadius: BorderRadius.circular(s.frameRadius + 4),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...header, body, ...footer],
      ),
    );
  }

  Widget _question(
    int q,
    int? picked,
    bool locked,
    MarkdownStyle s,
    HermesTokens t,
  ) {
    final question = qs[q];
    final practice = question.answer != null;
    final answered = picked != null;
    return Column(
      key: ValueKey('quiz-q$q'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            question.text,
            style: s.h3.copyWith(height: 1.3, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 14),
        for (final (i, o) in question.options.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _OptionButton(
            label: o,
            position: '${i + 1} of ${question.options.length}',
            selected: picked == i,
            verdict: practice && answered
                ? (i == question.answer
                      ? true
                      : picked == i
                      ? false
                      : null)
                : null,
            onTap: locked || (practice && answered) ? null : () => _pick(q, i),
            style: s,
          ),
        ],
        if (practice && answered && question.explain != null) ...[
          const SizedBox(height: 10),
          Text(question.explain!, style: s.body.copyWith(color: s.textMuted)),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            if (q > 0)
              TextButton.icon(
                onPressed: () => setState(() => _page = q - 1),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Back'),
                style: TextButton.styleFrom(
                  foregroundColor: s.textMuted,
                  minimumSize: const Size(48, 48),
                ),
              ),
            const Spacer(),
            if (answered && (practice || _page != null))
              TextButton.icon(
                onPressed: () => setState(() => _page = q + 1),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: Text(q + 1 < qs.length ? 'Next' : 'Review'),
                style: TextButton.styleFrom(
                  foregroundColor: t.accent,
                  minimumSize: const Size(48, 48),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _summary(
    Map<int, int> picks,
    bool locked,
    UiActionHandler h,
    MarkdownStyle s,
    HermesTokens t,
  ) {
    final practice = qs.any((q) => q.answer != null);
    final right = [
      for (final (i, q) in qs.indexed)
        if (q.answer != null && picks[i] == q.answer) i,
    ].length;
    return Column(
      key: const ValueKey('quiz-summary'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (practice)
          Text(
            '$right of ${qs.length} correct',
            style: s.h3.copyWith(fontWeight: FontWeight.w600),
          ),
        for (final (i, q) in qs.indexed)
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: locked ? null : () => setState(() => _page = i),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 26,
                        child: Text(
                          '${i + 1}.',
                          style: s.caption.copyWith(color: s.textMuted),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          q.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: s.caption.copyWith(color: s.text),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        picks[i] == null ? '–' : q.options[picks[i]!],
                        style: s.caption.copyWith(
                          color: q.answer == null
                              ? t.accent
                              : picks[i] == q.answer
                              ? s.success
                              : s.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: locked || !h.canSend || picks.length < qs.length
              ? null
              : () => _send(h),
          icon: Icon(
            locked ? Icons.check_rounded : Icons.send_rounded,
            size: 18,
          ),
          label: Text(
            locked
                ? (practice ? 'Results sent' : 'Answers sent')
                : (practice ? 'Send my results' : 'Send my answers'),
          ),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        ),
      ],
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.label,
    required this.position,
    required this.selected,
    required this.verdict,
    required this.onTap,
    required this.style,
  });
  final String label, position;
  final bool selected;

  /// Practice feedback: true = the right answer, false = a wrong pick.
  final bool? verdict;
  final VoidCallback? onTap;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final t = HermesTokens.of(context);
    final color = verdict == true
        ? s.success
        : verdict == false
        ? s.danger
        : selected
        ? t.accent
        : s.outline;
    final fill = verdict == null && selected
        ? t.accent.withValues(alpha: 0.10)
        : verdict == true
        ? s.success.withValues(alpha: 0.10)
        : verdict == false
        ? s.danger.withValues(alpha: 0.10)
        : null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: '$label, option $position',
      excludeSemantics: true,
      child: Material(
        color: fill ?? Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(
            color: color,
            width: selected || verdict != null ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 12),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: s.body.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (selected || verdict == true)
                    Positioned(
                      right: -32,
                      child: Icon(
                        verdict == false
                            ? Icons.close_rounded
                            : Icons.check_rounded,
                        size: 20,
                        color: color,
                      ),
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
