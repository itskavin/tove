// One ```openui fence in a reply: parsed as it streams, evaluated against a
// local state store, and drawn with Tove's own widgets (the blend rule: no
// fills, 1 px outlines group, colour only for state).
//
// Safety: nothing executes. Actions map only to sending a visible user
// message, opening a link through the confirm sheet, copying, or changing
// this block's local state. Pictures load through the bridge like markdown
// images. Limits: source size, rendered element count, and an evaluation
// budget, so a hostile program cannot hang the UI.

import 'dart:convert' show jsonEncode;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../interactive/checklist_store.dart' show UiBlockOrdinal;
import '../interactive/scope.dart';
import '../interactive/ui_block.dart' show UiFallback, UiPlaceholder;
import '../interactive/ui_entities.dart' show UiRemoteImage;
import '../interactive/ui_model.dart';
import '../interactive/ui_slider.dart';
import '../interactive/ui_widgets.dart';
import '../markdown/artifact.dart' show ArtifactCard;
import '../markdown/hermes_markdown.dart';
import '../shell/drawer_swipe.dart' show DrawerSwipeExclusion;
import '../theme/tokens.dart';
import 'charts.dart';
import 'lang/ast.dart';
import 'lang/builtins.dart' show jsString, toNumber, truthy;
import 'lang/evaluator.dart';
import 'lang/parser.dart';
import 'library.dart';

part 'chat_renderer.dart';

/// The fence info string.
const String openUiInfo = 'openui';

class OpenUiLimits {
  static const int maxSource = 24000;
  static const int maxElements = 400;
  static const int evalBudget = 50000;
  static const int maxSendChars = 300;
}

class OpenUiBlock extends StatefulWidget {
  const OpenUiBlock({
    super.key,
    required this.source,
    required this.complete,
    required this.style,
  });

  /// The fence body (OpenUI Lang).
  final String source;

  /// The fence is closed (or the reply finished).
  final bool complete;
  final MarkdownStyle style;

  @override
  State<OpenUiBlock> createState() => _OpenUiBlockState();
}

class _OpenUiBlockState extends State<OpenUiBlock> {
  StreamParser? _parser;

  /// The program was written for the round-9 Tove set (library_legacy.dart).
  bool _legacy = false;
  late ParseResult _result;
  final Map<String, Object?> _store = {};
  final Set<String> _touched = {};
  Map<String, Object?> _defaults = const {};
  bool _sent = false;

  /// Form field values: form name → field name → value ("" = no form).
  final Map<String, Map<String, Object?>> _forms = {};

  /// The fields each Form drew last, for its buttons.
  final Map<String, List<_FieldMeta>> _formMeta = {};

  /// Required fields left empty on the last submit, per form.
  final Map<String, Set<String>> _errors = {};

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(OpenUiBlock old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || old.complete != widget.complete) {
      _parse();
    }
  }

  void _parse() {
    var src = widget.source;
    if (src.length > OpenUiLimits.maxSource) {
      src = src.substring(0, OpenUiLimits.maxSource);
    }
    final legacy = isLegacyProgram(src);
    if (_parser == null || legacy != _legacy) {
      _legacy = legacy;
      _parser = StreamParser(
        legacy ? legacyLibrary : toveLibrary,
        unknownAsText: true,
      );
    }
    _result = _parser!.set(src, complete: widget.complete);
    _defaults = _result.stateDeclarations;
    for (final e in _defaults.entries) {
      // A default from a truncated statement is replaced when the full
      // statement arrives, unless the user changed it (spec §4 rule 6).
      if (!_touched.contains(e.key)) _store[e.key] = e.value;
    }
  }

  EvaluationContext _context() {
    late final EvaluationContext ctx;
    ctx = EvaluationContext(
      getState: (n) => _store[n],
      resolveRef: (name) {
        // No tools: a query shows its defaults, a mutation stays idle.
        for (final q in _result.queryStatements) {
          if (q.statementId == name) {
            return q.defaultsAst == null ? null : evaluate(q.defaultsAst!, ctx);
          }
        }
        return null;
      },
      actions: toveActions,
      budget: EvalBudget(OpenUiLimits.evalBudget),
    );
    return ctx;
  }

  void _write(String target, Object? value) {
    setState(() {
      _store[target] = value;
      _touched.add(target);
    });
  }

  /// Runs an action plan with the safe step mapping.
  Object? _fieldValue(String form, String name) => _forms[form]?[name];

  void _setField(String form, String name, Object? value) {
    setState(() {
      (_forms[form] ??= {})[name] = value;
      _errors[form]?.remove(name);
    });
  }

  /// A Form's button: checks required fields, then sends the label and
  /// the filled-in values as one visible user message.
  void _submit(String form, Object? action, String label, UiActionHandler h) {
    final fields = _formMeta[form] ?? const <_FieldMeta>[];
    String? shown(Object? v) {
      if (v == null) return null;
      if (v is List) {
        final t = v.map(jsString).where((x) => x.trim().isNotEmpty).join(', ');
        return t.isEmpty ? null : t;
      }
      if (v is Map) {
        final on = [
          for (final e in v.entries)
            if (truthy(e.value)) '${e.key}',
        ];
        return on.isEmpty ? null : on.join(', ');
      }
      final t = jsString(v).trim();
      return t.isEmpty ? null : t;
    }

    final missing = {
      for (final f in fields)
        if (f.required && shown(_fieldValue(form, f.name)) == null) f.name,
    };
    if (missing.isNotEmpty) {
      setState(() => _errors[form] = missing);
      return;
    }
    final parts = [
      for (final f in fields)
        if (shown(_fieldValue(form, f.name)) case final v?) '${f.label}: $v',
    ];
    final steps = [
      if (action is ActionPlan) ...action.steps,
      if (action is List)
        for (final a in action)
          if (a is ActionPlan) ...a.steps,
    ];
    final ask =
        steps.whereType<ToAssistantStep>().firstOrNull?.message ?? label;
    final text = parts.isEmpty ? ask : '$ask — ${parts.join('; ')}';
    _run(
      ActionPlan([
        ToAssistantStep(text),
        ...steps.where((x) => x is! ToAssistantStep),
      ]),
      label,
      h,
    );
  }

  void _run(Object? action, String label, UiActionHandler h, {String? item}) {
    final steps = <ActionStep>[
      if (action is ActionPlan) ...action.steps,
      if (action is List)
        for (final a in action)
          if (a is ActionPlan) ...a.steps,
      if (action == null) ToAssistantStep(label),
    ];
    final ctx = _context();
    for (final s in steps) {
      switch (s) {
        case ToAssistantStep():
          final text = cleanSendText(
            item == null || item.isEmpty || s.message.contains(item)
                ? s.message
                : '${s.message}: $item',
          );
          if (text.isEmpty || !h.canSend || _sent) continue;
          h.send(text);
          setState(() => _sent = true);
        case OpenUrlStep():
          h.openLink(s.url);
        case CustomStep(name: 'Copy'):
          final t = s.params['text'];
          if (t != null) h.copy(jsString(t));
        case SetStep():
          _write(s.target, evaluate(s.valueAst, ctx));
        case ResetStep():
          setState(() {
            for (final t in s.targets) {
              _store[t] = _defaults[t];
              _touched.remove(t);
            }
          });
        case RunStep() || CustomStep():
          break; // no tools in the app
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final errors = <OpenUiError>[];
    ElementNode? root;
    try {
      root = evaluateRoot(
        _result,
        _context(),
        _legacy ? legacyBindings : toveBindings,
        errors,
      );
    } catch (_) {
      root = null;
    }
    if (root == null) {
      if (!widget.complete) return UiPlaceholder(style: s);
      if (widget.source.trim().isEmpty) return const SizedBox.shrink();
      final codes = {
        for (final e in [..._result.meta.errors, ...errors]) e.code,
      };
      return UiFallback(
        source: widget.source,
        style: s,
        reason: codes.isEmpty ? null : codes.join(', '),
      );
    }
    final h = UiActionHandler.of(context);
    final _RendererBase r = _legacy
        ? _LegacyRenderer(this, h, s)
        : _ChatRenderer(this, h, s, HermesTokens.of(context).accent);
    return r.node(root);
  }
}

/// Text sent as the user's message: control and bidi characters removed,
/// trimmed, at most [OpenUiLimits.maxSendChars] characters.
String cleanSendText(String t) {
  final cleaned = t
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.length > OpenUiLimits.maxSendChars
      ? cleaned.substring(0, OpenUiLimits.maxSendChars)
      : cleaned;
}

bool _isHttps(String? u) {
  if (u == null) return false;
  final uri = Uri.tryParse(u.trim());
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

/// The Wikipedia title of an `entity:Title` picture reference, or null.
String? _entityRef(String? u) {
  if (u == null || !u.startsWith('entity:')) return null;
  final t = Uri.decodeComponent(u.substring(7)).replaceAll('_', ' ').trim();
  return t.isEmpty || t.length > 200 ? null : t;
}

bool _isPicture(String? u) => _isHttps(u) || _entityRef(u) != null;

String? _str(Object? v) {
  if (v == null || v is Undefined || v is ElementNode || v is ActionPlan) {
    return null;
  }
  if (v is ReactiveAssign) return null;
  final t = jsString(v).trim();
  return t.isEmpty ? null : t;
}

UiTone _tone(Object? v) => switch (_str(v)) {
  'good' || 'success' || 'ok' => UiTone.good,
  'warn' || 'warning' => UiTone.warn,
  'bad' || 'danger' || 'error' => UiTone.bad,
  'info' => UiTone.info,
  'tip' => UiTone.tip,
  _ => UiTone.neutral,
};

/// What both renderers share: the element budget, error containment,
/// columns and grids.
abstract class _RendererBase {
  _RendererBase(this.state, this.h, this.s);
  final _OpenUiBlockState state;
  final UiActionHandler h;
  final MarkdownStyle s;
  int _count = 0;

  double get gap => s.paragraphGap;

  Widget build(ElementNode e);

  List<ElementNode> _els(Object? v, [String? type]) => [
    if (v is List)
      for (final x in v)
        if (x is ElementNode && (type == null || x.typeName == type)) x,
    if (v is ElementNode && (type == null || v.typeName == type)) v,
  ];

  List<String> _strs(Object? v) => [
    if (v is List)
      for (final x in v) ?_str(x),
  ];

  List<double> _nums(Object? v) => [
    if (v is List)
      for (final x in v)
        if (x is num || x is String) toNumber(x),
  ];

  Widget node(Object? v) {
    if (v is ElementNode) {
      if (++_count > OpenUiLimits.maxElements) return const SizedBox.shrink();
      try {
        return KeyedSubtree(
          key: v.statementId == null ? null : ValueKey('oui:${v.statementId}'),
          child: build(v),
        );
      } catch (_) {
        return const SizedBox.shrink(); // render-error: contained
      }
    }
    if (v is List) return column([for (final x in v) node(x)]);
    final t = _str(v);
    return t == null ? const SizedBox.shrink() : _markdown(t);
  }

  Widget column(List<Widget> children, {double? spacing}) {
    final kids = [
      for (final c in children)
        if (c is! SizedBox || c.child != null || c.height != 0) c,
    ];
    if (kids.isEmpty) return const SizedBox.shrink();
    if (kids.length == 1) return kids.single;
    final g = spacing ?? gap;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kids.length; i++) ...[
          if (i > 0) SizedBox(height: g),
          kids[i],
        ],
      ],
    );
  }

  Widget _markdown(String text) => NoNestedUiBlocks(
    child: HermesMarkdown(text: text, style: s),
  );

  Widget _children(ElementNode e, [String key = 'children']) =>
      column([for (final c in _els(e.props[key])) node(c)]);

  TextStyle get _strong => s.body.copyWith(fontWeight: FontWeight.w600);

  String? _bound(Object? v) => v is ReactiveAssign ? v.target : null;

  /// Up to [columns] equal columns, fewer when narrow (150 dp each at 1×
  /// text). [equalHeight] marks card grids (12 dp apart when one column);
  /// cells align to the top: pictures inside cards size themselves with
  /// LayoutBuilder, which cannot report intrinsic heights.
  Widget _grid(List<Widget> kids, int columns, {bool equalHeight = false}) {
    if (kids.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final fit = (c.maxWidth / (150 * scale)).floor().clamp(1, 4);
        final cols = columns.clamp(1, fit);
        if (cols == 1) return column(kids, spacing: equalHeight ? 12 : null);
        final rows = <Widget>[];
        for (var i = 0; i < kids.length; i += cols) {
          final row = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) const SizedBox(width: 12),
                Expanded(
                  child: i + j < kids.length ? kids[i + j] : const SizedBox(),
                ),
              ],
            ],
          );
          rows.add(row);
        }
        return column(rows, spacing: 12);
      },
    );
  }
}

/// The round-9 Tove set (Stack, Title, Facts, Stats…).
class _LegacyRenderer extends _RendererBase {
  _LegacyRenderer(super.state, super.h, super.s);

  @override
  Widget build(ElementNode e) {
    final p = e.props;
    switch (e.typeName) {
      case unknownTextType:
        return Text(_str(p['text']) ?? '', style: s.body);
      case 'Stack':
        final g = switch (_str(p['gap'])) {
          'sm' => 8.0,
          'lg' => gap * 1.6,
          _ => null,
        };
        return column([
          for (final c in _els(p['children'])) node(c),
        ], spacing: g);
      case 'Row':
        return _row(_els(p['children']));
      case 'Grid':
        return _grid(
          [for (final c in _els(p['children'])) node(c)],
          (p['columns'] is num ? (p['columns']! as num).toInt() : 2).clamp(
            1,
            4,
          ),
        );
      case 'Card':
        return _card(e);
      case 'Carousel':
        return _carousel(e);
      case 'Tabs':
        final tabs = _els(p['items'], 'Tab');
        return _OuiTabs(
          style: s,
          labels: [for (final t in tabs) _str(t.props['label']) ?? ''],
          panes: [for (final t in tabs) _children(t)],
        );
      case 'Accordion':
        return column([
          for (final panel in _els(p['items'], 'Panel'))
            UiDetailsView(
              title: _str(panel.props['title']) ?? '',
              initiallyOpen: truthy(panel.props['open']),
              style: s,
              body: _children(panel),
            ),
        ], spacing: 0);
      case 'Separator':
        return Divider(height: 1, thickness: 1, color: s.hairline);
      case 'Title':
        final ts = switch (_str(p['size'])) {
          'sm' => s.h4,
          'lg' => s.h2,
          _ => s.h3,
        };
        return Semantics(
          header: true,
          child: Text(_str(p['text']) ?? '', style: ts),
        );
      case 'Text':
        final t = _str(p['text']) ?? '';
        return _str(p['tone']) == 'muted'
            ? Text(t, style: s.body.copyWith(color: s.textMuted))
            : _markdown(t);
      case 'Markdown':
        return _markdown(_str(p['text']) ?? '');
      case 'Callout':
        return UiElementView(
          style: s,
          element: UiCallout(
            tone: switch (_str(p['tone'])) {
              'tip' => UiTone.tip,
              'warning' => UiTone.warn,
              'danger' => UiTone.bad,
              'success' => UiTone.good,
              _ => UiTone.info,
            },
            title: _str(p['title']),
            body: _str(p['text']) ?? '',
          ),
        );
      case 'Badge':
        return Align(alignment: Alignment.centerLeft, child: _badge(e));
      case 'List':
        final items = _strs(p['items']);
        final numbered = truthy(p['numbered']);
        return _markdown(
          [
            for (final (i, t) in items.indexed)
              numbered ? '${i + 1}. $t' : '- $t',
          ].join('\n'),
        );
      case 'Steps':
        return _steps(_els(p['items'], 'Step'));
      case 'Table':
        return _table(p);
      case 'Facts':
        return _facts(_els(p['items'], 'Fact'));
      case 'ProsCons':
        return _prosCons(_strs(p['pros']), _strs(p['cons']));
      case 'Code':
        return CodeBlock(
          code: _str(p['code']) ?? '',
          language: _str(p['language']),
          style: s,
        );
      case 'Link':
        final url = _str(p['url']);
        final text = _str(p['text']) ?? url ?? '';
        if (!_isHttps(url)) return Text(text, style: s.body);
        return _markdown('[${text.replaceAll(']', r'\]')}](<$url>)');
      case 'Stats':
        return UiElementView(
          style: s,
          element: UiCards(
            items: [
              for (final x in _els(p['items'], 'Stat').take(4))
                UiCard(
                  label: _str(x.props['label']) ?? '',
                  value: _str(x.props['value']) ?? '—',
                  sub: _str(x.props['sub']),
                  tone: _tone(x.props['tone']),
                ),
            ],
          ),
        );
      case 'Metrics':
        return UiElementView(
          style: s,
          element: UiMetrics(
            items: [
              for (final x in _els(p['items'], 'Metric').take(6))
                UiMetric(
                  label: _str(x.props['label']) ?? '',
                  value: _str(x.props['value']) ?? '—',
                  unit: _str(x.props['unit']),
                  delta: _str(x.props['delta']),
                  tone: _tone(x.props['tone']),
                  trend: _nums(x.props['trend']).take(48).toList(),
                ),
            ],
          ),
        );
      case 'Gauges':
        return UiElementView(
          style: s,
          element: UiGauges(
            items: [
              for (final x in _els(p['items'], 'Gauge').take(6))
                () {
                  final max = x.props['max'] is num
                      ? toNumber(x.props['max'])
                      : 100.0;
                  return UiGauge(
                    label: _str(x.props['label']) ?? '',
                    value: toNumber(x.props['value']),
                    max: max <= 0 ? 100 : max,
                    unit: _str(x.props['unit']) ?? (max == 100 ? '%' : ''),
                    tone: _tone(x.props['tone']),
                  );
                }(),
            ],
          ),
        );
      case 'Progress':
        return _progress(p);
      case 'Status':
        return UiElementView(
          style: s,
          element: UiStatus(
            title: _str(p['title']) ?? '',
            state: _state(p['state']),
            summary: _str(p['summary']),
            updated: _str(p['updated']),
          ),
        );
      case 'Services':
        return UiElementView(
          style: s,
          element: UiServices(
            title: _str(p['title']),
            items: [
              for (final x in _els(p['items'], 'Service').take(20))
                UiService(
                  name: _str(x.props['name']) ?? '',
                  state: _state(x.props['state']),
                  latency: _str(x.props['latency']),
                  sub: _str(x.props['sub']),
                ),
            ],
          ),
        );
      case 'Alerts':
        return UiElementView(
          style: s,
          element: UiAlerts(
            items: [
              for (final x in _els(p['items'], 'Alert').take(8))
                UiAlert(
                  tone: _tone(x.props['tone']),
                  title: _str(x.props['title']) ?? '',
                  body: _str(x.props['body']),
                  time: _str(x.props['time']),
                ),
            ],
          ),
        );
      case 'Chart':
        final series = [
          for (final x in _els(p['series'], 'Series').take(3))
            UiSeries(
              name: _str(x.props['name']) ?? '',
              values: _nums(x.props['values']).take(60).toList(),
            ),
        ].where((x) => x.values.isNotEmpty).toList();
        if (series.isEmpty) return const SizedBox.shrink();
        return UiElementView(
          style: s,
          element: UiChart(
            kind: _str(p['kind']) == 'bar' ? UiChartKind.bar : UiChartKind.line,
            title: _str(p['title']),
            unit: _str(p['unit']),
            labels: _strs(p['labels']).take(60).toList(),
            series: series,
          ),
        );
      case 'Image':
        final src = _str(p['src']);
        if (_entityRef(src) != null) {
          return LayoutBuilder(
            builder: (context, c) => UiRemoteImageBox(
              url: src!,
              width: c.maxWidth,
              height: (c.maxWidth * 0.6).clamp(120.0, 260.0),
              style: s,
              radius: 14,
            ),
          );
        }
        if (!_isHttps(src)) return const SizedBox.shrink();
        final alt = (_str(p['alt']) ?? '').replaceAll(RegExp(r'[\[\]]'), '');
        return _markdown('![$alt](<$src>)');
      case 'Gallery':
        final all = _strs(p['images']).where(_isPicture).take(8).toList();
        if (all.isEmpty) return const SizedBox.shrink();
        if (all.any((u) => _entityRef(u) != null)) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, u) in all.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  UiRemoteImageBox(
                    url: u,
                    width: 200,
                    height: 150,
                    style: s,
                    radius: 14,
                  ),
                ],
              ],
            ),
          );
        }
        final imgs = all;
        return _markdown(imgs.map((u) => '![](<$u>)').join(' '));
      case 'Entities':
        return UiElementView(
          style: s,
          element: UiEntities(
            items: [
              for (final x in _els(p['items'], 'Entity').take(6))
                UiEntity(
                  name: _str(x.props['name']) ?? '',
                  sub: _str(x.props['sub']),
                  image: _isHttps(_str(x.props['image']))
                      ? _str(x.props['image'])
                      : null,
                  about: _str(x.props['about']),
                  page: _entityRef(_str(x.props['image'])) == null
                      ? null
                      : 'https://en.wikipedia.org/wiki/'
                            '${Uri.encodeComponent(_entityRef(_str(x.props['image']))!.replaceAll(' ', '_'))}',
                ),
            ],
          ),
        );
      case 'News':
        return UiElementView(
          style: s,
          element: UiNews(
            items: [
              for (final x in _els(p['items'], 'Article').take(8))
                if (_isHttps(_str(x.props['url'])))
                  UiNewsItem(
                    title: _str(x.props['title']) ?? '',
                    url: _str(x.props['url'])!,
                    source: _str(x.props['source']),
                    date: _str(x.props['date']),
                    image: _isHttps(_str(x.props['image']))
                        ? _str(x.props['image'])
                        : null,
                  ),
            ],
          ),
        );
      case 'Buttons':
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final b in _els(p['items'], 'Button').take(6)) _button(b),
          ],
        );
      case 'Button':
        return Align(alignment: Alignment.centerLeft, child: _button(e));
      case 'Options':
        final items = _strs(p['items']).take(8).toList();
        if (items.length < 2) return const SizedBox.shrink();
        return UiElementView(
          style: s,
          element: UiOptions(
            prompt: _str(p['prompt']),
            many: false,
            options: [for (final t in items) UiOption(t, cleanSendText(t))],
          ),
        );
      case 'Checklist':
        final items = _strs(p['items']).take(20).toList();
        if (items.isEmpty) return const SizedBox.shrink();
        return UiElementView(
          style: s,
          element: UiChecklist(
            title: _str(p['title']),
            sections: [
              UiCheckSection(items: [for (final t in items) UiCheckItem(t)]),
            ],
          ),
        );
      case 'Input':
        return _input(p);
      case 'Slider':
        return _slider(p);
      case 'Toggle':
        return _toggle(p);
      case 'Select':
        return _select(p);
    }
    return const SizedBox.shrink();
  }

  UiTone _state(Object? v) => switch (_str(v)) {
    'ok' || 'up' || 'healthy' || 'good' => UiTone.good,
    'warn' || 'degraded' || 'warning' => UiTone.warn,
    'bad' || 'down' || 'offline' || 'error' => UiTone.bad,
    'info' => UiTone.info,
    _ => UiTone.neutral,
  };

  static const _inline = {'Badge', 'Button', 'Link', unknownTextType};

  Widget _row(List<ElementNode> kids) {
    if (kids.every((k) => _inline.contains(k.typeName))) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final k in kids)
            k.typeName == 'Badge'
                ? _badge(k)
                : k.typeName == 'Button'
                ? _button(k)
                : node(k),
        ],
      );
    }
    return _grid([for (final k in kids) node(k)], kids.length.clamp(1, 3));
  }

  Widget _card(ElementNode e) {
    final p = e.props;
    final title = _str(p['title']);
    final sub = _str(p['subtitle']);
    final image = _str(p['image']);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: s.outline),
        borderRadius: BorderRadius.circular(s.frameRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isPicture(image))
            LayoutBuilder(
              builder: (context, c) => UiRemoteImageBox(
                url: image!,
                width: c.maxWidth,
                height: (c.maxWidth * 0.56).clamp(96.0, 200.0),
                style: s,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: column([
              if (title != null || sub != null)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) Text(title, style: _strong),
                    if (sub != null) Text(sub, style: s.caption),
                  ],
                ),
              _children(e),
            ], spacing: 10),
          ),
        ],
      ),
    );
  }

  Widget _carousel(ElementNode e) {
    final kids = _els(e.props['children']);
    if (kids.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, k) in kids.indexed) ...[
            if (i > 0) const SizedBox(width: 12),
            SizedBox(width: 240, child: node(k)),
          ],
        ],
      ),
    );
  }

  Color _toneColor(UiTone t) => switch (t) {
    UiTone.good => s.success,
    UiTone.warn || UiTone.tip => s.warning,
    UiTone.bad => s.danger,
    _ => s.textMuted,
  };

  Widget _badge(ElementNode e) {
    final c = _toneColor(_tone(e.props['tone']));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _str(e.props['text']) ?? '',
        style: s.caption.copyWith(color: c),
      ),
    );
  }

  Widget _steps(List<ElementNode> steps) {
    if (steps.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, st) in steps.indexed)
          _StepRow(
            index: i + 1,
            last: i == steps.length - 1,
            style: s,
            title: _str(st.props['title']) ?? '',
            time: _str(st.props['time']),
            body: _str(st.props['body']) == null
                ? null
                : _markdown(_str(st.props['body'])!),
          ),
      ],
    );
  }

  Widget _table(Map<String, Object?> p) {
    // Positional: an empty header (the usual blank corner over a label
    // column) must keep its column, unlike _strs, which drops empties.
    final raw = p['columns'];
    final cols = [
      if (raw is List)
        for (final x in raw) _str(x) ?? '',
    ];
    final rows = p['rows'];
    if (cols.isEmpty || rows is! List) return const SizedBox.shrink();
    String cell(Object? v) =>
        (_str(v) ?? '').replaceAll('|', r'\|').replaceAll('\n', ' ');
    final b = StringBuffer()
      ..writeln('| ${cols.map(cell).join(' | ')} |')
      ..writeln('|${List.filled(cols.length, ' --- ').join('|')}|');
    for (final r in rows.take(60)) {
      if (r is! List) continue;
      b.writeln(
        '| ${[for (var i = 0; i < cols.length; i++) cell(i < r.length ? r[i] : null)].join(' | ')} |',
      );
    }
    return _markdown(b.toString());
  }

  Widget _facts(List<ElementNode> facts) {
    if (facts.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, f) in facts.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: s.hairline),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    _str(f.props['label']) ?? '',
                    style: s.body.copyWith(color: s.textMuted),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Text(
                    _str(f.props['value']) ?? '',
                    style: s.body,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _prosCons(List<String> pros, List<String> cons) {
    Widget side(
      String title,
      IconData head,
      IconData mark,
      Color c,
      List<String> items,
    ) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(head, size: 18, color: s.text),
            const SizedBox(width: 6),
            Text(title, style: _strong),
          ],
        ),
        const SizedBox(height: 6),
        for (final t in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(mark, size: 16, color: c),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(t, style: s.body)),
              ],
            ),
          ),
      ],
    );
    return _grid([
      if (pros.isNotEmpty)
        side(
          'Pros',
          Icons.thumb_up_outlined,
          Icons.check_rounded,
          s.success,
          pros,
        ),
      if (cons.isNotEmpty)
        side(
          'Cons',
          Icons.thumb_down_outlined,
          Icons.close_rounded,
          s.danger,
          cons,
        ),
    ], 2);
  }

  Widget _progress(Map<String, Object?> p) {
    final max = p['max'] is num && toNumber(p['max']) > 0
        ? toNumber(p['max'])
        : 100.0;
    final v = toNumber(p['value']).clamp(0, max).toDouble();
    final shown = max == 100
        ? '${v.round()}%'
        : '${jsString(v)} / ${jsString(max)}';
    return Semantics(
      label: _str(p['label']),
      value: shown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(_str(p['label']) ?? '', style: s.body)),
              Text(shown, style: s.body.copyWith(color: s.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: s.text.withValues(alpha: 0.12)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: max == 0 ? 0 : v / max,
                    child: ColoredBox(color: s.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _sends(Object? action) {
    if (action == null) return true;
    final steps = [
      if (action is ActionPlan) ...action.steps,
      if (action is List)
        for (final a in action)
          if (a is ActionPlan) ...a.steps,
    ];
    return steps.any((x) => x is ToAssistantStep);
  }

  Widget _button(ElementNode e) {
    final label = _str(e.props['label']) ?? '';
    final action = e.props['action'];
    final sends = _sends(action);
    final enabled =
        !sends || (h.canSend && !state._sent && h.nextUserMessage == null);
    return UiPill(
      label: label,
      style: s,
      primary: truthy(e.props['primary']),
      quiet: !truthy(e.props['primary']),
      onTap: enabled ? () => state._run(action, label, h) : null,
    );
  }

  Widget _label(String? t) =>
      t == null ? const SizedBox.shrink() : Text(t, style: s.body);

  Widget _input(Map<String, Object?> p) {
    final target = _bound(p['value']);
    final value = target == null
        ? _str(p['value'])
        : _str(state._store[target]);
    return _OuiTextField(
      key: ValueKey('in:$target'),
      style: s,
      label: _str(p['label']),
      hint: _str(p['placeholder']),
      value: value ?? '',
      onChanged: target == null ? null : (t) => state._write(target, t),
    );
  }

  Widget _slider(Map<String, Object?> p) {
    final target = _bound(p['value']);
    final min = toNumber(p['min']);
    var max = toNumber(p['max']);
    if (max <= min) max = min + 1;
    final step = p['step'] is num && toNumber(p['step']) > 0
        ? toNumber(p['step'])
        : (max - min) / 100;
    final raw = target == null ? p['value'] : state._store[target];
    final v = toNumber(raw).clamp(min, max).toDouble();
    final unit = _str(p['unit']);
    final shown = '${jsString(v)}${unit == null ? '' : ' $unit'}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _label(_str(p['label']))),
            Text(shown, style: _strong),
          ],
        ),
        UiSlider(
          value: v,
          min: min,
          max: max,
          step: step,
          active: s.text,
          inactive: s.text.withValues(alpha: 0.12),
          thumbFill: s.background,
          thumbRing: s.text.withValues(alpha: 0.3),
          semanticLabel: _str(p['label']),
          semanticValue: shown,
          onChanged: (nv) {
            if (target == null) return;
            h.selectionHaptic();
            state._write(target, nv);
          },
        ),
      ],
    );
  }

  Widget _toggle(Map<String, Object?> p) {
    final target = _bound(p['value']);
    final v = truthy(target == null ? p['value'] : state._store[target]);
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(child: _label(_str(p['label']))),
          Switch.adaptive(
            value: v,
            onChanged: target == null ? null : (nv) => state._write(target, nv),
          ),
        ],
      ),
    );
  }

  Widget _select(Map<String, Object?> p) {
    final target = _bound(p['value']);
    final cur = _str(target == null ? p['value'] : state._store[target]);
    final opts = _strs(p['options']).take(12).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_str(p['label']) != null) ...[
          _label(_str(p['label'])),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in opts)
              UiPill(
                label: o,
                style: s,
                quiet: true,
                selected: o == cur,
                semanticsSelected: o == cur,
                onTap: target == null ? null : () => state._write(target, o),
              ),
          ],
        ),
      ],
    );
  }
}

/// A picture loaded through the bridge: an http(s) URL, or an
/// `entity:Title` reference that the bridge's entity info resolves.
class UiRemoteImageBox extends StatelessWidget {
  const UiRemoteImageBox({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    required this.style,
    this.radius = 0,
  });
  final String url;
  final double width, height, radius;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final entity = _entityRef(url);
    return UiRemoteImage(
      url: entity == null ? url : null,
      entityName: entity,
      width: width,
      height: height,
      style: style,
      radius: radius,
      collapseWhenEmpty: entity != null,
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.last,
    required this.style,
    required this.title,
    this.time,
    this.body,
  });
  final int index;
  final bool last;
  final MarkdownStyle style;
  final String title;
  final String? time;
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: s.outline, width: 1.5),
                  ),
                  child: Text(
                    '$index',
                    style: s.caption.copyWith(color: s.text),
                  ),
                ),
                if (!last)
                  Expanded(child: Container(width: 1.5, color: s.hairline)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14, top: 1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: s.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (time != null) Text(time!, style: s.caption),
                  if (body != null) ...[const SizedBox(height: 4), body!],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OuiTabs extends StatefulWidget {
  const _OuiTabs({
    required this.style,
    required this.labels,
    required this.panes,
  });
  final MarkdownStyle style;
  final List<String> labels;
  final List<Widget> panes;

  @override
  State<_OuiTabs> createState() => _OuiTabsState();
}

class _OuiTabsState extends State<_OuiTabs> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.panes.length;
    if (n == 0) return const SizedBox.shrink();
    final i = _i.clamp(0, n - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Like segmented choices: a drag across the tab pills never opens
        // the sidebar.
        DrawerSwipeExclusion(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var j = 0; j < n && j < 8; j++)
                UiPill(
                  label: widget.labels[j].isEmpty ? 'Part ${j + 1}' : widget.labels[j],
                  style: widget.style,
                  quiet: true,
                  selected: j == i,
                  semanticsSelected: j == i,
                  onTap: () => setState(() => _i = j),
                ),
            ],
          ),
        ),
        SizedBox(height: widget.style.paragraphGap),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(key: ValueKey(i), child: widget.panes[i]),
        ),
      ],
    );
  }
}

class _OuiTextField extends StatefulWidget {
  const _OuiTextField({
    super.key,
    required this.style,
    required this.value,
    this.label,
    this.hint,
    this.onChanged,
    this.lines = 1,
    this.keyboard,
    this.obscure = false,
  });
  final MarkdownStyle style;
  final String value;
  final String? label, hint;
  final ValueChanged<String>? onChanged;
  final int lines;
  final TextInputType? keyboard;
  final bool obscure;

  @override
  State<_OuiTextField> createState() => _OuiTextFieldState();
}

class _OuiTextFieldState extends State<_OuiTextField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_OuiTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c),
    );
    return TextField(
      controller: _c,
      enabled: widget.onChanged != null,
      onChanged: widget.onChanged,
      maxLength: widget.lines > 1 ? 1000 : 300,
      minLines: widget.lines,
      maxLines: widget.obscure ? 1 : (widget.lines > 1 ? widget.lines + 4 : 1),
      keyboardType:
          widget.keyboard ??
          (widget.lines > 1 ? TextInputType.multiline : null),
      obscureText: widget.obscure,
      style: s.body,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        counterText: '',
        isDense: true,
        border: border(s.outline),
        enabledBorder: border(s.outline),
        focusedBorder: border(s.text.withValues(alpha: 0.6)),
      ),
    );
  }
}
