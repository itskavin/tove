import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

import '../interactive/ui_model.dart';
import '../theme/motion.dart';
import 'footnotes.dart';
import 'links.dart';
import 'markdown_style.dart';
import 'md_blocks.dart';
import 'md_render.dart';

/// Renders a markdown reply that may still be arriving (spec §5.3).
///
/// Give it the full text received so far, either as [text] (rebuild the
/// parent with the longer string) or through a [ValueListenable] with
/// [StreamingMarkdown.listenable] (no parent rebuild per chunk). Set
/// [isStreaming] to false once the reply is complete.
///
/// How it renders:
///
/// - The text is cut into blocks at blank lines outside code fences.
///   Completed blocks are parsed once and their widgets are cached, so they
///   are never rebuilt while the reply grows; each sits in its own
///   [RepaintBoundary]. Only the trailing block is re-parsed per update,
///   after [repairPartial] has made partial markdown (an open fence, half a
///   table or link, an unclosed `**`) render as if it were complete.
/// - New text fades in from 0 to 1 over 240 ms, linear. With reduced motion
///   ([Motion.reduced]) it appears at once.
/// - With [smoothReveal], bursts are revealed at up to 90 characters per
///   second, faster when more than 400 characters behind, and the rest is
///   flushed within 300 ms once [isStreaming] turns false. Off with reduced
///   motion.
/// - Text present when the widget is first built with [isStreaming] false is
///   shown at once, with no animation (history messages).
///
/// The widget has no fixed width and no scrolling of its own; code blocks and
/// tables scroll horizontally. It is selectable when placed inside a
/// [SelectionArea] (set [selectable] to add one here).
class StreamingMarkdown extends StatefulWidget {
  const StreamingMarkdown({
    super.key,
    required String this.text,
    this.isStreaming = true,
    this.style,
    this.onLinkTap,
    this.onRevealed,
    this.smoothReveal = true,
    this.selectable = false,
  }) : source = null;

  /// Like the default constructor, but reads the text from [source] and
  /// rebuilds only itself when it changes.
  const StreamingMarkdown.listenable({
    super.key,
    required ValueListenable<String> this.source,
    this.isStreaming = true,
    this.style,
    this.onLinkTap,
    this.onRevealed,
    this.smoothReveal = true,
    this.selectable = false,
  }) : text = null;

  /// The full text received so far. Each value should extend the previous
  /// one; any other change starts the rendering over.
  final String? text;

  /// The full text received so far, as a listenable.
  final ValueListenable<String>? source;

  /// True while more text may arrive. While true the trailing block is
  /// treated as partial.
  final bool isStreaming;

  /// Defaults to [MarkdownStyle.of] (the app's design tokens).
  final MarkdownStyle? style;

  /// Called with a link's destination (only http, https and mailto links are
  /// tappable). Defaults to [confirmAndOpen]: a confirm sheet showing the
  /// host, then the external browser.
  final MarkdownLinkTap? onLinkTap;

  /// Called once, after [isStreaming] has turned false and every character is
  /// visible (the fade included). Use it to fade in the message's action row.
  /// Not called for a widget that was never streaming.
  final VoidCallback? onRevealed;

  /// Reveal bursts at a capped rate (spec §5.3, "rate smoothing").
  final bool smoothReveal;

  /// Wraps the message in its own [SelectionArea]. Leave false when an
  /// ancestor already provides one.
  final bool selectable;

  @override
  State<StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _Mark {
  _Mark(this.start);
  final int start;

  /// Ticker time of the first frame that showed this run; null until then.
  Duration? at;
}

final _uiFence = RegExp(
  r'^ {0,3}(`{3,}|~{3,})[ \t]*hermes-ui',
  multiLine: true,
);

class _Block {
  _Block(this.start, this.source, this.complete, this.nodes)
    : length = textLength(nodes),
      refs = footnoteRefsIn(source),
      uiBlocks = source.contains(hermesUiInfo)
          ? _uiFence.allMatches(source).length
          : 0,
      hidden = nodes.isEmpty || _onlySuggestions(nodes);

  /// The footnote labels this block cites.
  final Set<String> refs;

  /// hermes-ui fences in this block.
  final int uiBlocks;

  /// Renders nothing (footnote definitions, a lifted `suggestions` block).
  final bool hidden;

  /// The footnote definitions the frozen widget was built with.
  List<Footnote?>? frozenRefs;

  static bool _onlySuggestions(List<md.Node> nodes) {
    final real = nodes
        .where((n) => !(n is md.Text && n.text.trim().isEmpty))
        .toList();
    if (real.length != 1) return false;
    final n = real.single;
    if (n is! md.Element || n.tag != 'pre') return false;
    final code = n.children?.whereType<md.Element>().firstOrNull;
    if (code?.attributes['class'] != 'language-$hermesUiInfo') return false;
    return parseHermesUi(code!.textContent.trimRight()).element
        is UiSuggestions;
  }

  final int start;
  final String source;
  final bool complete;
  final List<md.Node> nodes;
  final int length;
  List<_Mark> marks = [];

  /// The cached widget, once the block is complete and fully opaque.
  Widget? frozen;

  BlockEdge get first => edgeOf(nodes.firstOrNull);
  BlockEdge get last => edgeOf(nodes.lastOrNull);
}

class _StreamingMarkdownState extends State<StreamingMarkdown>
    with SingleTickerProviderStateMixin {
  static const fadeDuration = Duration(milliseconds: 240);
  static const _coalesce = Duration(milliseconds: 40);
  static const _maxMarks = 8;
  static const _rate = 90.0; // characters per second
  static const _catchUpAfter = 400;
  static const _catchUpTau = 0.25; // seconds to drain the excess
  static const _flushWithin = 0.3; // seconds

  late final Ticker _ticker = createTicker(_onTick);
  Duration _now = Duration.zero;
  Duration _lastTick = Duration.zero;

  String _target = '';
  int _shown = 0;
  double _carry = 0;
  int? _flushFrom;

  final List<_Block> _blocks = [];
  final Map<int, Widget> _groupCache = {};
  bool _reduced = false;
  Map<String, Footnote> _footnotes = const {};
  bool _sawStreaming = false;
  bool _revealedSent = false;
  MarkdownStyle? _style;

  String get _incoming => widget.source?.value ?? widget.text ?? '';

  bool get _animate => !_reduced && TickerMode.valuesOf(context).enabled;

  @override
  void initState() {
    super.initState();
    widget.source?.addListener(_onSource);
    _sawStreaming = widget.isStreaming;
    _target = _incoming;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = _style == null;
    _reduced = Motion.reduced(context);
    if (_reduced) {
      for (final b in _blocks) {
        b.marks.clear();
      }
    }
    final style = widget.style ?? MarkdownStyle.of(context);
    if (style != _style) {
      _style = style;
      _groupCache.clear();
      for (final b in _blocks) {
        b.frozen = null;
      }
    }
    if (first) {
      // History (not streaming) or reduced motion: show everything now.
      if (!widget.isStreaming || !_animate || !widget.smoothReveal) {
        _revealTo(_target.length, fade: widget.isStreaming && _animate);
      }
      _kick();
    }
  }

  @override
  void didUpdateWidget(StreamingMarkdown old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      old.source?.removeListener(_onSource);
      widget.source?.addListener(_onSource);
    }
    if (widget.style != old.style) {
      final style = widget.style ?? MarkdownStyle.of(context);
      if (style != _style) {
        _style = style;
        _groupCache.clear();
        for (final b in _blocks) {
          b.frozen = null;
        }
      }
    }
    if (widget.isStreaming) _sawStreaming = true;
    _setTarget(_incoming, endChanged: old.isStreaming != widget.isStreaming);
  }

  @override
  void dispose() {
    widget.source?.removeListener(_onSource);
    _ticker.dispose();
    super.dispose();
  }

  void _onSource() => setState(() => _setTarget(_incoming));

  void _setTarget(String t, {bool endChanged = false}) {
    final shownText = _target.substring(0, _shown);
    if (!t.startsWith(shownText)) {
      // Not a continuation: start over.
      _blocks.clear();
      _groupCache.clear();
      _shown = 0;
      _carry = 0;
      _flushFrom = null;
      _revealedSent = false;
    }
    _target = t;
    if (!_animate || !widget.smoothReveal) {
      _revealTo(t.length, fade: _animate);
    } else if (endChanged && _shown == t.length) {
      // Only the streaming flag changed: re-check the trailing block.
      _revealTo(_shown, fade: true);
    }
    _kick();
  }

  /// Makes the first [len] characters visible and re-splits the open region.
  void _revealTo(int len, {required bool fade}) {
    len = len.clamp(0, _target.length);
    // Never cut a surrogate pair.
    if (len > 0 &&
        len < _target.length &&
        (_target.codeUnitAt(len - 1) & 0xFC00) == 0xD800) {
      len--;
    }
    _shown = len;
    final text = _target.substring(0, len);
    _footnotes = scanFootnotes(text);
    final allDone = !widget.isStreaming && len == _target.length;

    // Re-split from the start of the last block; earlier blocks are final.
    final from = _blocks.isEmpty ? 0 : _blocks.last.start;
    final ranges = splitBlockRanges(text, from: from);
    final old = _blocks.isEmpty ? null : _blocks.removeLast();

    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      final raw = text.substring(r.start, r.end);
      final complete = i < ranges.length - 1 || allDone;
      _Block block;
      if (old != null &&
          old.start == r.start &&
          old.complete == complete &&
          old.source == raw) {
        block = old;
      } else {
        final src = complete ? raw : repairPartial(raw);
        block = _Block(r.start, raw, complete, parseMarkdownBlock(src));
        if (old != null && old.start == r.start) {
          block.marks = old.marks.where((m) => m.start < block.length).toList();
          _addMark(block, old.length, fade);
        } else {
          _addMark(block, 0, fade);
        }
      }
      _blocks.add(block);
    }
  }

  void _addMark(_Block b, int from, bool fade) {
    if (!fade || b.length <= from) return;
    final last = b.marks.lastOrNull;
    if (last != null && (last.at == null || _now - last.at! < _coalesce)) {
      return; // Arrived within the same moment: share the run.
    }
    b.marks.add(_Mark(from));
    if (b.marks.length > _maxMarks) b.marks.removeAt(0);
  }

  bool get _busy =>
      _shown < _target.length || _blocks.any((b) => b.marks.isNotEmpty);

  void _kick() {
    if (_busy && _animate) {
      if (!_ticker.isActive) {
        _now = Duration.zero;
        _lastTick = Duration.zero;
        _ticker.start();
      }
    } else {
      if (_ticker.isActive) _ticker.stop();
      for (final b in _blocks) {
        b.marks.clear();
      }
      _maybeRevealed();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _now = elapsed;

    // Rate smoothing.
    final backlog = _target.length - _shown;
    if (backlog > 0) {
      if (!widget.smoothReveal) {
        _revealTo(_target.length, fade: true);
      } else {
        var rate = _rate;
        if (backlog > _catchUpAfter) {
          rate += (backlog - _catchUpAfter) / _catchUpTau;
        }
        if (!widget.isStreaming) {
          _flushFrom ??= _shown;
          rate = math.max(rate, (_target.length - _flushFrom!) / _flushWithin);
        }
        _carry += rate * dt;
        final n = _carry.floor();
        if (n > 0) {
          _carry -= n;
          _revealTo(_shown + n, fade: true);
        }
      }
    }

    // Fade bookkeeping: stamp new runs, drop finished ones.
    for (final b in _blocks) {
      for (final m in b.marks) {
        m.at ??= elapsed;
      }
      b.marks.removeWhere((m) => elapsed - m.at! >= fadeDuration);
    }
    setState(() {});
    if (!_busy) {
      _ticker.stop();
      _maybeRevealed();
    }
  }

  void _maybeRevealed() {
    if (_revealedSent || !_sawStreaming || widget.isStreaming) return;
    if (_shown < _target.length || _blocks.any((b) => b.marks.isNotEmpty)) {
      return;
    }
    _revealedSent = true;
    final cb = widget.onRevealed;
    if (cb != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) cb();
      });
    }
  }

  void _handleLink(String href) {
    final cb = widget.onLinkTap;
    if (cb != null) {
      cb(href);
    } else {
      confirmAndOpen(context, href);
    }
  }

  FadeRuns? _fadeFor(_Block b) {
    if (b.marks.isEmpty) return null;
    final ms = fadeDuration.inMicroseconds;
    return FadeRuns(
      [for (final m in b.marks) m.start],
      [
        for (final m in b.marks)
          m.at == null
              ? 0.0
              : ((_now - m.at!).inMicroseconds / ms).clamp(0.0, 1.0),
      ],
    );
  }

  List<Footnote?> _refsOf(_Block b) => [for (final l in b.refs) _footnotes[l]];

  bool _sameRefs(List<Footnote?> a, List<Footnote?>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Widget _blockWidget(int i, _Block b, int uiOrdinal) {
    if (b.frozen != null) return b.frozen!;
    final prev = i > 0 ? _blocks[i - 1] : null;
    final w = RepaintBoundary(
      key: ValueKey<int>(i),
      child: MdBlockView(
        index: i,
        nodes: b.nodes,
        style: _style!,
        onLinkTap: _handleLink,
        fade: _fadeFor(b),
        complete: b.complete,
        afterSourcesLabel:
            prev != null && isSourcesLabel(prev.nodes.lastOrNull),
        footnotes: b.refs.isEmpty ? const {} : _footnotes,
        uiOrdinal: uiOrdinal,
      ),
    );
    if (b.complete && b.marks.isEmpty) {
      b.frozen = w;
      b.frozenRefs = _refsOf(b);
    }
    return w;
  }

  /// Blocks are laid out in fixed groups of [_groupSize]. A group whose
  /// blocks are all final is cached as one widget in its own
  /// [RepaintBoundary], so an update lays out and paints only the open group
  /// plus one child per finished group, however long the reply is.
  static const _groupSize = 16;

  @override
  Widget build(BuildContext context) {
    final s = _style!;
    // A finished block that cites a footnote rebuilds once the definition
    // arrives (definitions come at the end of a reply).
    for (var i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      if (b.frozen != null &&
          b.refs.isNotEmpty &&
          !_sameRefs(_refsOf(b), b.frozenRefs)) {
        b.frozen = null;
        _groupCache.remove(i ~/ _groupSize);
      }
    }
    final groups = <Widget>[];
    var uiOrdinal = 0;
    _Block? prev;
    final groupCount = (_blocks.length + _groupSize - 1) ~/ _groupSize;
    for (var g = 0; g < groupCount; g++) {
      final from = g * _groupSize;
      final to = math.min(from + _groupSize, _blocks.length);
      final cached = _groupCache[g];
      if (cached != null) {
        groups.add(cached);
        for (var i = from; i < to; i++) {
          uiOrdinal += _blocks[i].uiBlocks;
        }
        for (var i = to - 1; i >= from; i--) {
          if (!_blocks[i].hidden) {
            prev = _blocks[i];
            break;
          }
        }
        continue;
      }
      final children = <Widget>[];
      var allFrozen = to - from == _groupSize;
      for (var i = from; i < to; i++) {
        final b = _blocks[i];
        final ordinal = uiOrdinal;
        uiOrdinal += b.uiBlocks;
        if (b.hidden) {
          if (!b.complete) allFrozen = false;
          continue;
        }
        if (prev != null) {
          children.add(
            SizedBox(
              key: ValueKey<String>('gap$i'),
              height: gapBetween(prev.last, b.first, s),
            ),
          );
        }
        children.add(_blockWidget(i, b, ordinal));
        if (b.frozen == null) allFrozen = false;
        prev = b;
      }
      final group = RepaintBoundary(
        key: ValueKey<String>('group$g'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
      if (allFrozen) _groupCache[g] = group;
      groups.add(group);
    }
    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: groups,
    );
    if (widget.selectable) body = SelectionArea(child: body);
    return body;
  }
}
