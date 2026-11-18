import 'package:material_ui/material_ui.dart';

import '../markdown/markdown_style.dart';
import '../theme/motion.dart';
import '../openui/plain_text.dart' show openUiFollowUps, openUiPlainText;
import 'html_view.dart' show sanitizeHtml;
import 'ui_model.dart';

final _fence = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[ \t]*hermes-ui[ \t]*\n([\s\S]*?)\n {0,3}\1[`~]*[ \t]*$',
  multiLine: true,
);

final _openUiFence = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[ \t]*openui[ \t]*\n([\s\S]*?)\n {0,3}\1[`~]*[ \t]*$',
  multiLine: true,
);

final _htmlFence = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[ \t]*hermes-html[ \t]*\n([\s\S]*?)\n {0,3}\1[`~]*[ \t]*$',
  multiLine: true,
);

/// The bodies of the complete hermes-ui fences in [markdown], in order.
List<String> hermesUiSources(String markdown) => [
  for (final m in _fence.allMatches(markdown)) m[2]!,
];

/// The follow-up suggestions of a reply: the items of its last valid
/// `suggestions` block (at most 3), or an empty list. Show them with
/// [HermesSuggestions] under the latest reply's action row once it has
/// finished streaming.
List<String> extractSuggestions(String markdown) {
  var out = const <String>[];
  if (markdown.contains('FollowUp')) {
    for (final m in _openUiFence.allMatches(markdown)) {
      final f = openUiFollowUps(m[2]!);
      if (f.isNotEmpty) out = f;
    }
  }
  if (!markdown.contains(hermesUiInfo)) return out;
  for (final src in hermesUiSources(markdown)) {
    final e = parseHermesUi(src).element;
    if (e is UiSuggestions) out = e.items;
  }
  return out;
}

/// [markdown] with every hermes-ui block replaced by its readable text
/// (prompt, labels and values in order; never JSON), for Read aloud and
/// Share (§3.7). Invalid blocks become "Interactive content.".
/// Suggestions are dropped.
String hermesUiPlainText(String markdown) {
  if (markdown.contains(hermesHtmlInfo)) {
    markdown = markdown.replaceAllMapped(
      _htmlFence,
      (m) => sanitizeHtml(m[2]!).plainText,
    );
  }
  if (markdown.contains('openui')) {
    markdown = markdown.replaceAllMapped(
      _openUiFence,
      (m) => openUiPlainText(m[2]!),
    );
  }
  if (!markdown.contains(hermesUiInfo)) return markdown;
  return markdown.replaceAllMapped(_fence, (m) {
    final e = parseHermesUi(m[2]!).element;
    if (e == null) return 'Interactive content.';
    return e.plainText;
  });
}

/// Follow-up suggestion rows (§3.5 `suggestions`): 40 dp `surface`
/// stadiums with a return glyph, 8 dp apart, fading and rising in with a
/// 40 ms stagger. Tapping one calls [onSend] with its text.
class HermesSuggestions extends StatelessWidget {
  const HermesSuggestions({
    super.key,
    required this.items,
    required this.onSend,
    this.style,
  });

  final List<String> items;
  final ValueChanged<String> onSend;
  final MarkdownStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = style ?? MarkdownStyle.of(context);
    final reduced = Motion.reduced(context);
    final ts = s.control.copyWith(fontWeight: FontWeight.w400);
    return Semantics(
      container: true,
      label: 'Suggestions',
      explicitChildNodes: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _Rise(
              delay: Duration(milliseconds: 40 * i),
              reduced: reduced,
              child: Semantics(
                button: true,
                label: items[i],
                excludeSemantics: true,
                onTap: () => onSend(items[i]),
                child: Material(
                  color: s.surface,
                  shape: const StadiumBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSend(items[i]),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.subdirectory_arrow_right_rounded,
                              size: MediaQuery.textScalerOf(context).scale(16),
                              color: s.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Flexible(child: Text(items[i], style: ts)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Rise extends StatelessWidget {
  const _Rise({
    required this.delay,
    required this.reduced,
    required this.child,
  });
  final Duration delay;
  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduced) return child;
    const run = Duration(milliseconds: 180);
    final total = delay + run;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Motion.emphasizedDecel),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// What a finished reply adds under its action row: its follow-up
/// suggestions (the hermes-ui blocks themselves render in place inside the
/// markdown). Use [HermesReplyExtras.maybe] where a nullable builder is
/// expected, such as live mode's `LivePanel.blockBuilder`.
class HermesReplyExtras extends StatelessWidget {
  const HermesReplyExtras({
    super.key,
    required this.suggestions,
    required this.onSend,
    this.style,
  });

  /// The extras for [markdown], or null when there are none or the reply is
  /// still [streaming] (suggestions appear only after the stream ends).
  static Widget? maybe(
    String markdown, {
    required bool streaming,
    required ValueChanged<String>? onSend,
    MarkdownStyle? style,
  }) {
    if (streaming || onSend == null) return null;
    final items = extractSuggestions(markdown);
    if (items.isEmpty) return null;
    return HermesReplyExtras(suggestions: items, onSend: onSend, style: style);
  }

  final List<String> suggestions;
  final ValueChanged<String> onSend;
  final MarkdownStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: HermesSuggestions(items: suggestions, onSend: onSend, style: style),
  );
}
