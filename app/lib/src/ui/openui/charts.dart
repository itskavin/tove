// OpenUI's chart components drawn natively: BarChart, LineChart, AreaChart,
// HorizontalBarChart, RadarChart, PieChart, RadialChart,
// SingleStackedBarChart and ScatterChart. Layout follows OpenUI's condensed
// chat charts (legend under the plot, three grid lines, first/middle/last
// x labels); colours are Tove's accent first, then muted neutrals and the
// state colours, so a chart blends with the reply.

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:flutter/foundation.dart' show listEquals;

import '../interactive/ui_model.dart' show uiNumber;
import '../markdown/markdown_style.dart';
import '../theme/tokens.dart';

enum OuiChartKind {
  bar,
  line,
  area,
  horizontalBar,
  radar,
  pie,
  radial,
  stackedBar,
  scatter,
}

class OuiSeries {
  const OuiSeries(this.name, this.values);
  final String name;
  final List<double> values;
}

class OuiScatter {
  const OuiScatter(this.name, this.points);
  final String name;
  final List<Offset> points;
}

class OuiChartData {
  const OuiChartData({
    required this.kind,
    this.labels = const [],
    this.series = const [],
    this.values = const [],
    this.scatter = const [],
    this.stacked = false,
    this.donut = false,
    this.semi = false,
    this.step = false,
    this.smooth = false,
    this.xLabel,
    this.yLabel,
    this.height,
  });

  final OuiChartKind kind;
  final List<String> labels;
  final List<OuiSeries> series;

  /// One-dimensional charts (pie, radial, stacked bar).
  final List<double> values;
  final List<OuiScatter> scatter;
  final bool stacked, donut, semi, step, smooth;
  final String? xLabel, yLabel;
  final double? height;

  bool get oneD =>
      kind == OuiChartKind.pie ||
      kind == OuiChartKind.radial ||
      kind == OuiChartKind.stackedBar;

  bool get isEmpty => switch (kind) {
    OuiChartKind.scatter => scatter.every((s) => s.points.isEmpty),
    _ when oneD => values.isEmpty,
    _ => series.every((s) => s.values.isEmpty),
  };

  String get kindLabel => switch (kind) {
    OuiChartKind.bar => 'Bar chart',
    OuiChartKind.line => 'Line chart',
    OuiChartKind.area => 'Area chart',
    OuiChartKind.horizontalBar => 'Bar chart',
    OuiChartKind.radar => 'Radar chart',
    OuiChartKind.pie => donut ? 'Donut chart' : 'Pie chart',
    OuiChartKind.radial => 'Radial chart',
    OuiChartKind.stackedBar => 'Stacked bar',
    OuiChartKind.scatter => 'Scatter chart',
  };

  /// What Read aloud and screen readers get: every value with its label.
  String get plainText {
    final out = <String>[];
    if (oneD) {
      for (var i = 0; i < values.length; i++) {
        out.add(
          '${i < labels.length ? labels[i] : 'Part ${i + 1}'}: ${uiNumber(values[i])}',
        );
      }
    } else if (kind == OuiChartKind.scatter) {
      for (final s in scatter) {
        out.add('${s.name}: ${s.points.length} points');
      }
    } else {
      for (final s in series) {
        final pairs = [
          for (var i = 0; i < s.values.length; i++)
            '${i < labels.length ? '${labels[i]} ' : ''}${uiNumber(s.values[i])}',
        ];
        out.add('${s.name.isEmpty ? '' : '${s.name}: '}${pairs.join(', ')}');
      }
    }
    return out.join('. ');
  }
}

/// The chart palette: accent, then muted text, then the state colours.
List<Color> ouiPalette(MarkdownStyle s, Color accent) => [
  accent,
  s.textMuted,
  s.warning,
  s.success,
  s.danger,
  Color.lerp(accent, s.text, 0.5)!,
];

class OuiChartView extends StatelessWidget {
  const OuiChartView({super.key, required this.data, required this.style});
  final OuiChartData data;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final d = data;
    if (d.isEmpty) return const SizedBox.shrink();
    final accent = HermesTokens.of(context).accent;
    final palette = ouiPalette(s, accent);
    final scaler = MediaQuery.textScalerOf(context);
    final legend = d.oneD
        ? [
            for (var i = 0; i < d.values.length; i++)
              (
                i < d.labels.length ? d.labels[i] : 'Part ${i + 1}',
                palette[i % palette.length],
              ),
          ]
        : d.kind == OuiChartKind.scatter
        ? [
            for (final (i, x) in d.scatter.indexed)
              (x.name, palette[i % palette.length]),
          ]
        : [
            for (final (i, x) in d.series.indexed)
              (x.name, palette[i % palette.length]),
          ];
    final round =
        d.kind == OuiChartKind.pie ||
        d.kind == OuiChartKind.radial ||
        d.kind == OuiChartKind.radar;
    final h = d.kind == OuiChartKind.stackedBar
        ? 28.0
        : d.kind == OuiChartKind.horizontalBar
        ? math.max(1, d.labels.length) *
                  (scaler.scale(14) + 14) *
                  math.max(1, d.stacked ? 1 : d.series.length).clamp(1, 3) +
              8
        : round
        ? (d.semi ? 130.0 : 200.0)
        : (d.height ?? 180).clamp(120.0, 320.0).toDouble();
    final painter = _OuiChartPainter(
      d,
      colors: palette,
      grid: s.hairline,
      label: s.caption,
      text: s.text,
      background: s.background,
      textScaler: scaler,
    );
    return Semantics(
      label: '${d.kindLabel}. ${d.plainText}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d.yLabel != null && !round && !d.oneD)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(d.yLabel!, style: s.caption),
            ),
          SizedBox(
            height: h.toDouble(),
            child: CustomPaint(painter: painter),
          ),
          if (d.xLabel != null && !round && !d.oneD)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                d.xLabel!,
                style: s.caption,
                textAlign: TextAlign.center,
              ),
            ),
          if (legend.length > 1 || d.oneD)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  for (final (i, (name, c)) in legend.indexed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          d.oneD ? '$name ${_pct(d.values, i)}' : name,
                          style: s.caption,
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _pct(List<double> v, int i) {
    final total = v.fold<double>(0, (a, b) => a + math.max(0, b));
    if (total <= 0 || i >= v.length) return '';
    return '${(math.max(0, v[i]) / total * 100).round()}%';
  }
}

class _OuiChartPainter extends CustomPainter {
  _OuiChartPainter(
    this.d, {
    required this.colors,
    required this.grid,
    required this.label,
    required this.text,
    required this.background,
    required this.textScaler,
  });

  final OuiChartData d;
  final List<Color> colors;
  final Color grid, text, background;
  final TextStyle label;
  final TextScaler textScaler;

  Color _c(int i) => colors[i % colors.length];

  static String compact(double v) {
    final a = v.abs();
    if (a >= 1e9) return '${uiNumber(v / 1e9)}B';
    if (a >= 1e6) return '${uiNumber(v / 1e6)}M';
    if (a >= 1e4) return '${uiNumber(v / 1e3)}k';
    return uiNumber(v);
  }

  TextPainter _text(String s, {double? max}) => TextPainter(
    text: TextSpan(text: s, style: label),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: max ?? double.infinity);

  @override
  void paint(Canvas canvas, Size size) {
    switch (d.kind) {
      case OuiChartKind.pie:
        _pie(canvas, size);
      case OuiChartKind.radial:
        _radial(canvas, size);
      case OuiChartKind.stackedBar:
        _stacked1d(canvas, size);
      case OuiChartKind.radar:
        _radar(canvas, size);
      case OuiChartKind.horizontalBar:
        _hbar(canvas, size);
      case OuiChartKind.scatter:
        _scatter(canvas, size);
      case OuiChartKind.bar || OuiChartKind.line || OuiChartKind.area:
        _xy(canvas, size);
    }
  }

  // ── Cartesian: bar, line, area

  void _xy(Canvas canvas, Size size) {
    final series = d.series.where((s) => s.values.isNotEmpty).toList();
    if (series.isEmpty) return;
    final n = series.map((x) => x.values.length).reduce(math.max);
    final bar = d.kind == OuiChartKind.bar;
    final stack = d.stacked && bar;
    final all = stack
        ? [
            for (var i = 0; i < n; i++)
              series.fold<double>(
                0,
                (a, s) =>
                    a + (i < s.values.length ? math.max(0, s.values[i]) : 0),
              ),
          ]
        : [for (final x in series) ...x.values];
    var lo = all.reduce(math.min), hi = all.reduce(math.max);
    if ((bar || d.kind == OuiChartKind.area) && lo > 0) lo = 0;
    if (hi == lo) {
      hi += 1;
      if (!bar) lo -= 1;
    }
    final ticks = [hi, (hi + lo) / 2, lo];
    final tickText = [for (final v in ticks) _text(compact(v))];
    final left = tickText.map((t) => t.width).reduce(math.max) + 8;
    final hasX = d.labels.isNotEmpty;
    final xh = hasX ? _text('0').height + 6 : 0.0;
    final plot = Rect.fromLTRB(left, 6, size.width, size.height - xh);
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final (i, v) in ticks.indexed) {
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), gridPaint);
      final t = tickText[i];
      t.paint(canvas, Offset(0, yy - t.height / 2));
    }
    double slotX(int i) => plot.left + plot.width / n * (i + 0.5);
    double lineX(int i) =>
        n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
    if (bar) {
      final slot = plot.width / n;
      final k = stack ? 1 : series.length;
      final bw = math.min(28.0, slot * 0.7 / k);
      for (var i = 0; i < n; i++) {
        var base = 0.0;
        for (var j = 0; j < series.length; j++) {
          final vals = series[j].values;
          if (i >= vals.length) continue;
          final v = vals[i];
          final cx = stack ? slotX(i) : slotX(i) - bw * k / 2 + bw * (j + 0.5);
          final from = stack ? base : 0.0;
          final to = stack ? base + math.max(0, v) : v;
          if (stack) base = to;
          final top = y(math.max(from, to)), bottom = y(math.min(from, to));
          final r = Rect.fromLTRB(
            cx - bw / 2 + 1,
            top,
            cx + bw / 2 - 1,
            bottom,
          );
          final last = !stack || j == series.length - 1;
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              r,
              topLeft: Radius.circular(last ? 3 : 0),
              topRight: Radius.circular(last ? 3 : 0),
            ),
            Paint()..color = _c(j),
          );
        }
      }
    } else {
      for (final (j, s) in series.indexed) {
        final vals = s.values;
        final pts = [
          for (var i = 0; i < vals.length; i++) Offset(lineX(i), y(vals[i])),
        ];
        final path = _path(pts);
        if (d.kind == OuiChartKind.area ||
            (series.length == 1 && pts.length > 1)) {
          final fill = Path.from(path)
            ..lineTo(pts.last.dx, plot.bottom)
            ..lineTo(pts.first.dx, plot.bottom)
            ..close();
          final a = d.kind == OuiChartKind.area ? 0.28 : 0.18;
          canvas.drawPath(
            fill,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _c(j).withValues(alpha: a),
                  _c(j).withValues(alpha: 0),
                ],
              ).createShader(plot),
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..color = _c(j),
        );
        canvas.drawCircle(pts.last, 3, Paint()..color = _c(j));
      }
    }
    if (hasX) {
      final labels = d.labels;
      final picks = labels.length <= 4
          ? {for (var i = 0; i < labels.length; i++) i}
          : {0, labels.length ~/ 2, labels.length - 1};
      final maxW = plot.width / math.min(4, math.max(1, picks.length)) - 4;
      for (final i in picks) {
        if (i < 0 || i >= labels.length) continue;
        final t = _text(labels[i], max: maxW);
        final cx = bar ? slotX(i) : lineX(i);
        final dx = (cx - t.width / 2).clamp(plot.left, size.width - t.width);
        t.paint(canvas, Offset(dx.toDouble(), plot.bottom + 6));
      }
    }
  }

  Path _path(List<Offset> pts) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      if (d.step) {
        p
          ..lineTo(b.dx, a.dy)
          ..lineTo(b.dx, b.dy);
      } else if (d.smooth) {
        final mx = (a.dx + b.dx) / 2;
        p.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
      } else {
        p.lineTo(b.dx, b.dy);
      }
    }
    return p;
  }

  // ── Horizontal bars

  void _hbar(Canvas canvas, Size size) {
    final series = d.series.where((s) => s.values.isNotEmpty).toList();
    if (series.isEmpty) return;
    final n = series.map((x) => x.values.length).reduce(math.max);
    final stack = d.stacked;
    double total(int i) => series.fold<double>(
      0,
      (a, s) => a + (i < s.values.length ? math.max(0, s.values[i]) : 0),
    );
    final hi = stack
        ? [for (var i = 0; i < n; i++) total(i)].reduce(math.max)
        : [for (final s in series) ...s.values].reduce(math.max);
    final max = hi <= 0 ? 1.0 : hi;
    final labelW = math.min(size.width * 0.38, 140.0);
    final rowH = size.height / n;
    final k = stack ? 1 : series.length;
    final bh = math.min(14.0, (rowH - 8) / k);
    for (var i = 0; i < n; i++) {
      final top = rowH * i;
      if (i < d.labels.length) {
        final t = _text(d.labels[i], max: labelW - 8);
        t.paint(canvas, Offset(0, top + rowH / 2 - t.height / 2));
      }
      var base = 0.0;
      final valueW = _text('0000').width;
      final plotW = size.width - labelW - valueW;
      for (var j = 0; j < series.length; j++) {
        final vals = series[j].values;
        if (i >= vals.length) continue;
        final v = math.max(0.0, vals[i]);
        final cy = stack
            ? top + rowH / 2
            : top + rowH / 2 - bh * k / 2 + bh * (j + 0.5);
        final x0 = labelW + (stack ? base / max * plotW : 0);
        final w = v / max * plotW;
        if (stack) base += v;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x0, cy - bh / 2 + 1, math.max(2, w), bh - 2),
            const Radius.circular(3),
          ),
          Paint()..color = _c(j),
        );
        if (!stack || j == series.length - 1) {
          final t = _text(compact(stack ? total(i) : v));
          t.paint(canvas, Offset(x0 + w + 6, cy - t.height / 2));
        }
      }
    }
  }

  // ── Radar

  void _radar(Canvas canvas, Size size) {
    final n = d.labels.length;
    final series = d.series.where((s) => s.values.isNotEmpty).toList();
    if (n < 3 || series.isEmpty) return;
    final hi = [for (final s in series) ...s.values].reduce(math.max);
    final max = hi <= 0 ? 1.0 : hi;
    final lh = _text('0').height;
    final c = size.center(Offset.zero);
    final r = math.min(size.width / 2 - 56, size.height / 2 - lh - 4);
    Offset at(int i, double f) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      return c + Offset(math.cos(a), math.sin(a)) * r * f;
    }

    final gp = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid;
    for (final f in [1 / 3, 2 / 3, 1.0]) {
      canvas.drawPath(
        Path()..addPolygon([for (var i = 0; i < n; i++) at(i, f)], true),
        gp,
      );
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(c, at(i, 1), gp);
      final t = _text(d.labels[i], max: 96);
      final p = at(i, 1.12);
      t.paint(canvas, p - Offset(t.width / 2, t.height / 2));
    }
    for (final (j, s) in series.indexed) {
      final pts = [
        for (var i = 0; i < n; i++)
          at(
            i,
            i < s.values.length
                ? (math.max(0, s.values[i]) / max).toDouble()
                : 0,
          ),
      ];
      final path = Path()..addPolygon(pts, true);
      canvas.drawPath(path, Paint()..color = _c(j).withValues(alpha: 0.16));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _c(j),
      );
    }
  }

  // ── Pie / donut

  void _pie(Canvas canvas, Size size) {
    final vals = [for (final v in d.values) math.max(0.0, v)];
    final total = vals.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final semi = d.semi;
    final r = semi
        ? math.min(size.width / 2, size.height) - 2
        : math.min(size.width, size.height) / 2 - 2;
    final c = semi
        ? Offset(size.width / 2, size.height - 2)
        : size.center(Offset.zero);
    final sweepAll = semi ? math.pi : 2 * math.pi;
    var a = semi ? math.pi : -math.pi / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var i = 0; i < vals.length; i++) {
      final sweep = vals[i] / total * sweepAll;
      if (d.donut) {
        final w = r * 0.32;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r - w / 2),
          a + 0.012,
          math.max(0, sweep - 0.024),
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w
            ..color = _c(i),
        );
      } else {
        canvas.drawArc(rect, a, sweep, true, Paint()..color = _c(i));
        canvas.drawArc(
          rect,
          a,
          sweep,
          true,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = background,
        );
      }
      a += sweep;
    }
  }

  // ── Radial bars

  void _radial(Canvas canvas, Size size) {
    final vals = [for (final v in d.values) math.max(0.0, v)];
    if (vals.isEmpty) return;
    final hi = vals.reduce(math.max);
    final max = hi <= 0 ? 1.0 : hi;
    final c = size.center(Offset.zero);
    final outer = math.min(size.width, size.height) / 2 - 2;
    final n = vals.length.clamp(1, 8);
    final band = outer * 0.75 / n;
    for (var i = 0; i < n; i++) {
      final r = outer - band * i - band / 2;
      final rect = Rect.fromCircle(center: c, radius: r);
      final w = band * 0.7;
      canvas.drawArc(
        rect,
        0,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = grid,
      );
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * 0.85 * vals[i] / max,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = w
          ..color = _c(i),
      );
    }
  }

  // ── Single stacked bar

  void _stacked1d(Canvas canvas, Size size) {
    final vals = [for (final v in d.values) math.max(0.0, v)];
    final total = vals.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final h = math.min(size.height, 16.0);
    final top = (size.height - h) / 2;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, size.width, h),
        Radius.circular(h / 2),
      ),
    );
    var x = 0.0;
    for (var i = 0; i < vals.length; i++) {
      final w = vals[i] / total * size.width;
      canvas.drawRect(Rect.fromLTWH(x, top, w, h), Paint()..color = _c(i));
      if (i > 0) {
        canvas.drawLine(
          Offset(x, top),
          Offset(x, top + h),
          Paint()
            ..color = background
            ..strokeWidth = 2,
        );
      }
      x += w;
    }
    canvas.restore();
  }

  // ── Scatter

  void _scatter(Canvas canvas, Size size) {
    final pts = [for (final s in d.scatter) ...s.points];
    if (pts.isEmpty) return;
    var x0 = pts.map((p) => p.dx).reduce(math.min),
        x1 = pts.map((p) => p.dx).reduce(math.max);
    var y0 = pts.map((p) => p.dy).reduce(math.min),
        y1 = pts.map((p) => p.dy).reduce(math.max);
    if (x1 == x0) x1 += 1;
    if (y1 == y0) y1 += 1;
    final ticks = [y1, (y0 + y1) / 2, y0];
    final tt = [for (final v in ticks) _text(compact(v))];
    final left = tt.map((t) => t.width).reduce(math.max) + 8;
    final xh = _text('0').height + 6;
    final plot = Rect.fromLTRB(left + 4, 6, size.width - 4, size.height - xh);
    double x(double v) => plot.left + (v - x0) / (x1 - x0) * plot.width;
    double y(double v) => plot.bottom - (v - y0) / (y1 - y0) * plot.height;
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final (i, v) in ticks.indexed) {
      canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), gp);
      tt[i].paint(canvas, Offset(0, y(v) - tt[i].height / 2));
    }
    for (final v in [x0, (x0 + x1) / 2, x1]) {
      final t = _text(compact(v));
      t.paint(
        canvas,
        Offset(
          (x(v) - t.width / 2).clamp(plot.left, size.width - t.width),
          plot.bottom + 6,
        ),
      );
    }
    for (final (j, s) in d.scatter.indexed) {
      for (final p in s.points) {
        canvas.drawCircle(
          Offset(x(p.dx), y(p.dy)),
          4,
          Paint()..color = _c(j).withValues(alpha: 0.85),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_OuiChartPainter old) =>
      old.d != d ||
      old.grid != grid ||
      old.label != label ||
      old.textScaler != textScaler ||
      !listEquals(old.colors, colors);
}
