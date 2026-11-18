import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show KeyUpEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'markdown_style.dart';

/// A markdown table (chat-rendering-v2 §1.8): header in 14.5/20 700, body
/// in 14.5/20 400, cells padded 8 above and below with no left padding and
/// 24 dp after each column, columns between 112 and 300 dp with wrapping
/// text, 1 dp hairlines under the header and between rows only.
///
/// With [bleed] > 0 the horizontal scroller extends that far past the text
/// column on both sides (the thread gutter), so the table scrolls from
/// screen edge to screen edge and its rules run to the edge.
///
/// Only a table wider than the screen shows a scroll cue: a fade of
/// [MarkdownStyle.tableEdgeFade] on each side that still has columns past
/// it. It then also takes keyboard focus (arrow keys, Home, End scroll it)
/// and tells screen readers it scrolls sideways.
class MdTable extends StatefulWidget {
  const MdTable({
    super.key,
    required this.header,
    required this.rows,
    this.alignments = const [],
    this.numeric = const [],
    this.style,
    this.bleed = 0,
  });

  /// Header cells, already styled (rendered with [MarkdownStyle.tableHeader]).
  final List<InlineSpan> header;

  /// Body rows. Short rows are padded with empty cells.
  final List<List<InlineSpan>> rows;

  /// Per column: `left`, `center`, `right` or null.
  final List<String?> alignments;

  /// Per column: true when every body cell is a number (right-aligned,
  /// tabular figures, unless the column sets its own alignment).
  final List<bool> numeric;

  final MarkdownStyle? style;

  /// How far the scroller extends past each side of the text column.
  final double bleed;

  @override
  State<MdTable> createState() => _MdTableState();
}

class _MdTableState extends State<MdTable> {
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'MdTable');
  bool _moreRight = false;
  bool _moreLeft = false;
  bool _overflows = false;
  bool _focused = false;

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetrics m) {
    final overflows = m.maxScrollExtent > 0.5;
    final right = overflows && m.pixels < m.maxScrollExtent - 0.5;
    final left = overflows && m.pixels > m.minScrollExtent + 0.5;
    bool same() =>
        overflows == _overflows && right == _moreRight && left == _moreLeft;
    if (same()) return false;
    void apply() => setState(() {
      _overflows = overflows;
      _moreRight = right;
      _moreLeft = left;
    });
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !same()) apply();
      });
    }
    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || !_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final step = p.viewportDimension * 0.8;
    final target = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowRight => p.pixels + step,
      LogicalKeyboardKey.arrowLeft => p.pixels - step,
      LogicalKeyboardKey.home => p.minScrollExtent,
      LogicalKeyboardKey.end => p.maxScrollExtent,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    final to = target.clamp(p.minScrollExtent, p.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(to);
    } else {
      _scroll.animateTo(
        to,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }
    return KeyEventResult.handled;
  }

  bool _isNumeric(int col) =>
      col < widget.numeric.length && widget.numeric[col];

  TextAlign _align(int col) =>
      switch (col < widget.alignments.length ? widget.alignments[col] : null) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'left' => TextAlign.left,
        _ => _isNumeric(col) ? TextAlign.right : TextAlign.left,
      };

  @override
  Widget build(BuildContext context) {
    final s = widget.style ?? MarkdownStyle.of(context);
    final cols = [
      widget.header.length,
      for (final r in widget.rows) r.length,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    if (cols == 0) return const SizedBox.shrink();
    final bleed = widget.bleed;
    final pad = s.tableCellPadding;

    Widget cell(InlineSpan? span, int col, TextStyle style) => Padding(
      padding: EdgeInsets.fromLTRB(0, pad, s.tableColumnGap, pad),
      child: Text.rich(
        span ?? const TextSpan(text: ''),
        style: _isNumeric(col)
            ? style.copyWith(fontFeatures: const [FontFeature.tabularFigures()])
            : style,
        textAlign: _align(col),
      ),
    );

    TableRow row(
      List<InlineSpan> cells,
      TextStyle style, {
      bool header = false,
    }) => TableRow(
      children: [
        for (var c = 0; c < cols; c++)
          header
              ? Semantics(
                  header: true,
                  child: cell(c < cells.length ? cells[c] : null, c, style),
                )
              : cell(c < cells.length ? cells[c] : null, c, style),
        // Spacer: stretches the rules to the right edge.
        if (bleed > 0) const SizedBox.shrink(),
      ],
    );

    final colWidth = MaxColumnWidth(
      MinColumnWidth(
        const IntrinsicColumnWidth(),
        FixedColumnWidth(s.tableMaxColumnWidth),
      ),
      FixedColumnWidth(s.tableMinColumnWidth),
    );

    // IntrinsicWidth gives the table a tight width (its natural width, or
    // the bleed width when narrower) so the spacer column can fill it and
    // the rules reach the screen edge.
    Widget table(double minWidth) => ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: IntrinsicWidth(
        child: Table(
          defaultColumnWidth: colWidth,
          columnWidths: {
            if (bleed > 0)
              cols: const MaxColumnWidth(
                FixedColumnWidth(0),
                FlexColumnWidth(1),
              ),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder(horizontalInside: BorderSide(color: s.hairline)),
          children: [
            row(widget.header, s.tableHeader, header: true),
            for (final r in widget.rows) row(r, s.table),
          ],
        ),
      ),
    );

    Widget scroller(double minWidth) =>
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _onMetrics(n.metrics),
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) => _onMetrics(n.metrics),
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: bleed),
              child: table(minWidth),
            ),
          ),
        );

    Widget fade({required bool right}) => Positioned(
      top: 0,
      bottom: 0,
      left: right ? null : -bleed,
      right: right ? -bleed : null,
      width: s.tableEdgeFade,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: right ? Alignment.centerLeft : Alignment.centerRight,
              end: right ? Alignment.centerRight : Alignment.centerLeft,
              colors: [s.background.withValues(alpha: 0), s.background],
            ),
          ),
        ),
      ),
    );

    Widget body = LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        if (bleed <= 0 || !w.isFinite) return scroller(0);
        return OverflowBox(
          fit: OverflowBoxFit.deferToChild,
          minWidth: w + 2 * bleed,
          maxWidth: w + 2 * bleed,
          child: scroller(w + bleed),
        );
      },
    );

    if (s.tableEdgeFade > 0) {
      // Unclipped: the scroller and its fades run into the gutter.
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          if (_moreLeft) fade(right: false),
          if (_moreRight) fade(right: true),
        ],
      );
    }
    return Semantics(
      container: _overflows,
      hint: _overflows ? 'Table scrolls sideways for more columns' : null,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: _overflows,
        skipTraversal: !_overflows,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: _focused && _overflows
                  ? s.onAccentSoft
                  : const Color(0x00000000),
              width: 2,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: body,
        ),
      ),
    );
  }
}
