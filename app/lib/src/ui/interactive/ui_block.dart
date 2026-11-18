import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../markdown/code_block.dart';
import '../markdown/footnotes.dart';
import '../markdown/markdown_style.dart';
import '../theme/motion.dart';
import 'checklist_store.dart';
import 'scope.dart';
import 'ui_checklist.dart' show UiChecklistSkeleton;
import 'ui_model.dart';
import 'ui_widgets.dart';

/// One ```` ```hermes-ui ```` fenced block (chat-rendering-v2 §3.6, §3.7).
///
/// - While the JSON is still arriving ([complete] false and the JSON
///   unfinished): a 56 dp `surface` placeholder with a shimmering
///   "Preparing…" label, faded in after 150 ms.
/// - Once it parses: the native element, cross-faded in over 180 ms while
///   the height animates over 220 ms.
/// - Invalid JSON, an unknown type, a broken limit, `v > 1`, a block nested
///   in a `details` body, or more than [UiLimits.maxBlocksPerMessage] blocks
///   in a message: a collapsed "Interactive content couldn't be shown"
///   section holding the raw text.
class HermesUiBlock extends StatefulWidget {
  const HermesUiBlock({
    super.key,
    required this.source,
    this.complete = true,
    this.ordinal = 0,
    this.style,
    this.footnotes = const {},
  });

  /// The fence body (one JSON object).
  final String source;

  /// False while more of this block may arrive.
  final bool complete;

  /// This block's index among the message's hermes-ui blocks.
  final int ordinal;

  final MarkdownStyle? style;

  /// The message's footnote definitions, for elements that cite them.
  final Map<String, Footnote> footnotes;

  @override
  State<HermesUiBlock> createState() => _HermesUiBlockState();
}

class _HermesUiBlockState extends State<HermesUiBlock> {
  /// The state shown last (placeholder, element, fallback).
  Key? _shown;

  /// True for a moment after the state changed: only then does the height
  /// animate, so later size changes inside an element (a wrapping chip
  /// row, an opening section) apply at once.
  bool _switching = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final complete = widget.complete;
    final ordinal = widget.ordinal;
    final s = widget.style ?? MarkdownStyle.of(context);
    final Widget child;
    final Key key;
    if (ordinal >= UiLimits.maxBlocksPerMessage) {
      key = const ValueKey('fallback');
      child = UiFallback(source: source, style: s, reason: 'too many blocks');
    } else if (NoNestedUiBlocks.isNested(context)) {
      key = const ValueKey('fallback');
      child = UiFallback(source: source, style: s, reason: 'nested block');
    } else {
      final r = parseHermesUi(source);
      if (r.ok) {
        key = const ValueKey('element');
        child = widget.footnotes.isEmpty
            ? UiElementView(element: r.element!, style: s)
            : UiCitations(
                footnotes: widget.footnotes,
                child: UiElementView(element: r.element!, style: s),
              );
      } else if (!complete && looksIncompleteJson(source)) {
        key = const ValueKey('placeholder');
        child = UiPlaceholder(type: peekUiType(source), style: s);
      } else {
        key = const ValueKey('fallback');
        child = UiFallback(source: source, style: s, reason: r.error);
      }
    }
    if (_shown != null && _shown != key) {
      _switching = true;
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _switching = false);
      });
    }
    _shown = key;
    final fade = Motion.of(context, const Duration(milliseconds: 180));
    final size =
        _switching &&
            Motion.of(context, const Duration(seconds: 1)) > Duration.zero
        ? const Duration(milliseconds: 220)
        // Not zero: a zero-length AnimatedSize re-dirties itself in layout.
        : const Duration(microseconds: 1);
    return AnimatedSize(
      duration: size,
      curve: Motion.spatialCurve(context, Motion.emphasizedDecel),
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: fade,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [
            for (final p in previous)
              Positioned.fill(child: ClipRect(child: p)),
            ?current,
          ],
        ),
        // AnimatedSize loosens constraints: keep the full column width so
        // blocks share the text's left edge.
        child: KeyedSubtree(
          key: key,
          child: UiBlockOrdinal(
            ordinal: ordinal,
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    );
  }
}

/// The streaming placeholder: `surface`, radius 12, 56 dp, with a
/// shimmering caption. It fades in after 150 ms so short blocks never flash
/// it; with reduced motion it shows at once and does not shimmer.
class UiPlaceholder extends StatefulWidget {
  const UiPlaceholder({super.key, this.type, required this.style});
  final String? type;
  final MarkdownStyle style;

  static String labelFor(String? type) => switch (type) {
    'options' || 'actions' || 'suggestions' => 'Preparing options…',
    'calc' => 'Preparing calculator…',
    'checklist' || 'plan' => 'Preparing checklist…',
    _ => 'Preparing…',
  };

  @override
  State<UiPlaceholder> createState() => _UiPlaceholderState();
}

class _UiPlaceholderState extends State<UiPlaceholder>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    if (_reduced) {
      _c.stop();
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final label = UiPlaceholder.labelFor(widget.type);
    if (widget.type == 'checklist' || widget.type == 'plan') {
      // The block's own shape, so the reply does not jump when it lands.
      return Semantics(
        label: label,
        liveRegion: true,
        excludeSemantics: true,
        child: UiChecklistSkeleton(style: s),
      );
    }
    final text = Text(label, style: s.caption);
    final body = Container(
      constraints: const BoxConstraints(minHeight: 56),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(s.frameRadius),
      ),
      child: _reduced
          ? text
          : AnimatedBuilder(
              animation: _c,
              builder: (context, child) {
                final t = _c.value * 3 - 1;
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (r) => LinearGradient(
                    begin: Alignment(t - 1, 0),
                    end: Alignment(t + 1, 0),
                    colors: [s.textMuted, s.text, s.textMuted],
                    stops: const [0.3, 0.5, 0.7],
                  ).createShader(r),
                  child: child,
                );
              },
              child: text,
            ),
    );
    return Semantics(
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: _reduced
          ? body
          : TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 300),
              // 0–150 ms invisible, then a 150 ms fade.
              curve: const Interval(0.5, 1),
              builder: (context, v, child) => Opacity(opacity: v, child: child),
              child: body,
            ),
    );
  }
}

/// The fallback (§3.7): a collapsed section titled "Interactive content
/// couldn't be shown" with the raw text as a code block.
class UiFallback extends StatelessWidget {
  const UiFallback({
    super.key,
    required this.source,
    required this.style,
    this.reason,
  });

  final String source;
  final MarkdownStyle style;

  /// Why it failed (for debugging; shown under the raw text).
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return UiDetailsView(
      title: "Interactive content couldn't be shown",
      titleStyle: s.caption,
      style: s,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlock(code: source.trimRight(), language: 'hermes-ui', style: s),
          if (reason != null) ...[
            const SizedBox(height: 8),
            Text(reason!, style: s.caption),
          ],
        ],
      ),
    );
  }
}
