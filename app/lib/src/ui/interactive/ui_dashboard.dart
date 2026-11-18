/// The dashboard family (round 4): `status`, `metrics`, `gauges`,
/// `services`, `alerts` and `chart`.
///
/// They read as part of the reply (the user's rule for every block): no
/// fills or boxes, the reply's own text styles and gutter, thin dividers,
/// muted captions, small icons; colour only for state (dots, deltas,
/// rings, lines). Nothing here runs anything: service rows and alert
/// buttons send a visible follow-up message, like `send` buttons.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;

import 'package:material_ui/material_ui.dart';

import '../markdown/hermes_markdown.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'scope.dart';
import 'ui_model.dart';
import 'ui_widgets.dart' show UiPill;

/// The colour of a state or tone; [UiTone.neutral] is [neutral] (the
/// accent for rings and lines, muted for dots).
Color dashTone(UiTone t, MarkdownStyle s, {required Color neutral}) =>
    switch (t) {
      UiTone.good => s.success,
      UiTone.warn || UiTone.tip => s.warning,
      UiTone.bad => s.danger,
      UiTone.info || UiTone.neutral => neutral,
    };

/// A small state dot with a soft ring of the same colour.
class StateDot extends StatelessWidget {
  const StateDot({super.key, required this.color, this.size = 10});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size + 6,
    height: size + 6,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: 0.18),
    ),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    ),
  );
}

// ------------------------------------------------------------------ status

class UiStatusView extends StatelessWidget {
  const UiStatusView({super.key, required this.element, required this.style});
  final UiStatus element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = element;
    return Semantics(
      label: e.plainText,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: StateDot(
                color: dashTone(e.state, s, neutral: s.textMuted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title, style: s.bodyStrong),
                  if (e.summary != null)
                    Text(
                      e.summary!,
                      style: s.body.copyWith(color: s.textMuted),
                    ),
                ],
              ),
            ),
            if (e.updated != null) ...[
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(e.updated!, style: s.caption),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- metrics

class UiMetricsView extends StatelessWidget {
  const UiMetricsView({super.key, required this.element, required this.style});
  final UiMetrics element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final accent = HermesTokens.of(context).accent;
    return LayoutBuilder(
      builder: (context, c) {
        final n = element.items.length;
        final perRow = c.maxWidth < 520 ? math.min(2, n) : math.min(4, n);
        const gap = 20.0;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: 18,
          children: [
            for (final m in element.items)
              SizedBox(
                width: w,
                child: _MetricTile(metric: m, style: style, accent: accent),
              ),
          ],
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.metric,
    required this.style,
    required this.accent,
  });
  final UiMetric metric;
  final MarkdownStyle style;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final m = metric;
    final tone = m.tone == UiTone.neutral
        ? null
        : dashTone(m.tone, s, neutral: s.text);
    return Semantics(
      label: [
        '${m.label}: ${m.value}${m.unit == null ? '' : ' ${m.unit}'}',
        ?m.delta,
      ].join(', '),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.label, style: s.caption, maxLines: 2),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: m.value,
                  style: s.h3.copyWith(color: s.text),
                ),
                if (m.unit != null) ...[
                  const TextSpan(text: ' '),
                  TextSpan(text: m.unit, style: s.caption),
                ],
              ],
            ),
          ),
          if (m.delta != null)
            Text(
              m.delta!,
              style: s.caption.copyWith(color: tone ?? s.textMuted),
            ),
          if (m.trend.length >= 2) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 26,
              width: double.infinity,
              child: CustomPaint(
                painter: Sparkline(m.trend, color: tone ?? accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A trend line without axes; the last point gets a dot.
class Sparkline extends CustomPainter {
  Sparkline(this.values, {required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = hi - lo == 0 ? 1 : hi - lo;
    Offset at(int i) => Offset(
      size.width * i / (values.length - 1),
      3 + (size.height - 6) * (1 - (values[i] - lo) / span),
    );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = color,
      )
      ..drawCircle(at(values.length - 1), 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(Sparkline old) =>
      old.color != color || !_sameList(old.values, values);
}

bool _sameList(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ------------------------------------------------------------------ gauges

class UiGaugesView extends StatelessWidget {
  const UiGaugesView({super.key, required this.element, required this.style});
  final UiGauges element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final accent = HermesTokens.of(context).accent;
    return LayoutBuilder(
      builder: (context, c) {
        final n = element.items.length;
        // As many 80 dp columns as fit, at most six.
        const gap = 12.0;
        final perRow = math.max(
          1,
          math.min(math.min(n, 6), ((c.maxWidth + gap) / (80 + gap)).floor()),
        );
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: 16,
          children: [
            for (final g in element.items)
              SizedBox(
                width: w,
                child: _Gauge(gauge: g, style: style, accent: accent),
              ),
          ],
        );
      },
    );
  }
}

class _Gauge extends StatelessWidget {
  const _Gauge({
    required this.gauge,
    required this.style,
    required this.accent,
  });
  final UiGauge gauge;
  final MarkdownStyle style;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final g = gauge;
    final color = dashTone(g.tone, s, neutral: accent);
    final value = '${uiNumber(g.value)}${g.unit}';
    return Semantics(
      label:
          '${g.label}: $value${g.max != 100 || g.unit != '%' ? ' of ${uiNumber(g.max)}${g.unit}' : ''}'
          '${g.sub == null ? '' : ', ${g.sub}'}',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox.square(
            dimension: 68,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: g.fraction),
              duration: Motion.of(context, const Duration(milliseconds: 700)),
              curve: Motion.emphasizedDecel,
              builder: (context, v, child) => CustomPaint(
                painter: _Ring(v, color: color, track: s.hairline),
                child: child,
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      value,
                      style: s.bodyStrong.copyWith(fontSize: 15, height: 1.2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            g.label,
            style: s.caption.copyWith(color: s.text),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (g.sub != null)
            Text(
              g.sub!,
              style: s.caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.value, {required this.color, required this.track});
  final double value;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final r = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, p..color = track);
    if (value > 0) {
      canvas.drawArc(
        r,
        -math.pi / 2,
        math.pi * 2 * value,
        false,
        p..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_Ring old) =>
      old.value != value || old.color != color || old.track != track;
}

// ---------------------------------------------------------------- services

class UiServicesView extends StatelessWidget {
  const UiServicesView({super.key, required this.element, required this.style});
  final UiServices element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final ui = UiActionHandler.of(context);
    final rows = <Widget>[];
    for (final (i, x) in element.items.indexed) {
      if (i > 0) rows.add(Divider(height: 1, thickness: 1, color: s.hairline));
      rows.add(
        _ServiceRow(
          service: x,
          style: s,
          onTap: ui.canSend ? () => ui.send(x.followUp) : null,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (element.title != null)
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(element.title!, style: s.bodyStrong),
            ),
          ),
        ...rows,
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.service, required this.style, this.onTap});
  final UiService service;
  final MarkdownStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final x = service;
    return Semantics(
      button: onTap != null,
      label: [x.name, stateWord(x.state), ?x.latency, ?x.sub].join(', '),
      hint: onTap == null ? null : 'Sends: ${x.followUp}',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                StateDot(
                  color: dashTone(x.state, s, neutral: s.textMuted),
                  size: 8,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(x.name, style: s.body),
                      if (x.sub != null) Text(x.sub!, style: s.caption),
                    ],
                  ),
                ),
                if (x.latency != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    x.latency!,
                    style: s.caption.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: s.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ alerts

class UiAlertsView extends StatelessWidget {
  const UiAlertsView({super.key, required this.element, required this.style});
  final UiAlerts element;
  final MarkdownStyle style;

  static IconData iconFor(UiTone t) => switch (t) {
    UiTone.bad => Icons.error_outline_rounded,
    UiTone.warn || UiTone.tip => Icons.warning_amber_rounded,
    UiTone.good => Icons.check_circle_outline_rounded,
    UiTone.info || UiTone.neutral => Icons.info_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = style;
    final ui = UiActionHandler.of(context);
    final rows = <Widget>[];
    for (final (i, a) in element.items.indexed) {
      if (i > 0) rows.add(Divider(height: 1, thickness: 1, color: s.hairline));
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  iconFor(a.tone),
                  size: 20,
                  color: dashTone(a.tone, s, neutral: s.textMuted),
                  semanticLabel: stateWord(a.tone) == 'down'
                      ? 'Critical'
                      : a.tone == UiTone.warn
                      ? 'Warning'
                      : a.tone == UiTone.good
                      ? 'Resolved'
                      : 'Info',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(a.title, style: s.bodyStrong)),
                        if (a.time != null) ...[
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(a.time!, style: s.caption),
                          ),
                        ],
                      ],
                    ),
                    if (a.body != null)
                      Text(a.body!, style: s.body.copyWith(color: s.textMuted)),
                    if (a.actions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final b in a.actions)
                            UiPill(
                              label: b.label,
                              style: s,
                              height: 36,
                              horizontalPadding: 14,
                              onTap: ui.canSend
                                  ? () => ui.send(b.action.send!)
                                  : null,
                              semanticsHint: 'Sends: ${b.action.send}',
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

// ------------------------------------------------------------------- chart

class UiChartView extends StatelessWidget {
  const UiChartView({super.key, required this.element, required this.style});
  final UiChart element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = element;
    final accent = HermesTokens.of(context).accent;
    final palette = [accent, s.textMuted, s.warning];
    final colors = [
      for (final (i, x) in e.series.indexed)
        x.tone == null
            ? palette[i % palette.length]
            : dashTone(x.tone!, s, neutral: accent),
    ];
    return Semantics(
      label:
          '${e.kind == UiChartKind.bar ? 'Bar' : 'Line'} chart. '
          '${e.plainText}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.title != null || e.unit != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text.rich(
                TextSpan(
                  children: [
                    if (e.title != null)
                      TextSpan(text: e.title, style: s.bodyStrong),
                    if (e.unit != null)
                      TextSpan(
                        text: e.title == null ? e.unit : '  ${e.unit}',
                        style: s.caption,
                      ),
                  ],
                ),
              ),
            ),
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: ChartPainter(
                e,
                colors: colors,
                grid: s.hairline,
                label: s.caption,
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
          ),
          if (e.series.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final (i, x) in e.series.indexed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: colors[i],
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(x.name, style: s.caption),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Axis labels (low, middle, high) on the left, three hairlines, the first,
/// middle and last x labels below; lines with a soft fill under a single
/// series, or grouped bars with rounded tops.
class ChartPainter extends CustomPainter {
  ChartPainter(
    this.chart, {
    required this.colors,
    required this.grid,
    required this.label,
    required this.textScaler,
  });

  final UiChart chart;
  final List<Color> colors;
  final Color grid;
  final TextStyle label;
  final TextScaler textScaler;

  static String compact(double v) {
    final a = v.abs();
    if (a >= 1e9) return '${uiNumber(v / 1e9)}B';
    if (a >= 1e6) return '${uiNumber(v / 1e6)}M';
    if (a >= 1e4) return '${uiNumber(v / 1e3)}k';
    return uiNumber(v);
  }

  TextPainter _text(String s) => TextPainter(
    text: TextSpan(text: s, style: label),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final all = [for (final x in chart.series) ...x.values];
    if (all.isEmpty) return;
    final bar = chart.kind == UiChartKind.bar;
    var lo = all.reduce(math.min), hi = all.reduce(math.max);
    if (bar && lo > 0) lo = 0;
    if (hi == lo) {
      hi += 1;
      lo -= bar ? 0 : 1;
    }
    final ticks = [hi, (hi + lo) / 2, lo];
    final tickText = [for (final v in ticks) _text(compact(v))];
    final left = tickText.map((t) => t.width).reduce(math.max) + 8;
    final hasX = chart.labels.isNotEmpty;
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

    final n = chart.series.map((x) => x.values.length).reduce(math.max);
    if (bar) {
      final slot = plot.width / n;
      final k = chart.series.length;
      final bw = math.min(28.0, slot * 0.7 / k);
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < k; j++) {
          final vals = chart.series[j].values;
          if (i >= vals.length) continue;
          final cx = plot.left + slot * (i + 0.5) - bw * k / 2 + bw * (j + 0.5);
          final top = y(math.max(vals[i], 0)), base = y(math.min(vals[i], 0));
          final r = Rect.fromLTRB(cx - bw / 2 + 1, top, cx + bw / 2 - 1, base);
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              r,
              topLeft: const Radius.circular(3),
              topRight: const Radius.circular(3),
            ),
            Paint()..color = colors[j],
          );
        }
      }
    } else {
      double x(int i) =>
          n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
      for (final (j, s) in chart.series.indexed) {
        final vals = s.values;
        final path = Path()..moveTo(x(0), y(vals[0]));
        for (var i = 1; i < vals.length; i++) {
          path.lineTo(x(i), y(vals[i]));
        }
        if (chart.series.length == 1 && vals.length > 1) {
          final fill = Path.from(path)
            ..lineTo(x(vals.length - 1), plot.bottom)
            ..lineTo(x(0), plot.bottom)
            ..close();
          canvas.drawPath(
            fill,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  colors[j].withValues(alpha: 0.18),
                  colors[j].withValues(alpha: 0),
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
            ..color = colors[j],
        );
        canvas.drawCircle(
          Offset(x(vals.length - 1), y(vals.last)),
          3,
          Paint()..color = colors[j],
        );
      }
    }

    if (hasX) {
      final labels = chart.labels;
      final picks = {0, labels.length ~/ 2, labels.length - 1};
      for (final i in picks) {
        if (i < 0 || i >= labels.length) continue;
        final t = _text(labels[i]);
        final cx = bar
            ? plot.left + plot.width / n * (i + 0.5)
            : (n == 1
                  ? plot.center.dx
                  : plot.left + plot.width * i / math.max(1, n - 1));
        final dx = (cx - t.width / 2).clamp(plot.left, size.width - t.width);
        t.paint(canvas, Offset(dx, plot.bottom + 6));
      }
    }
  }

  @override
  bool shouldRepaint(ChartPainter old) =>
      old.chart != chart ||
      old.grid != grid ||
      old.label != label ||
      old.textScaler != textScaler ||
      !listEquals(old.colors, colors);
}
