// Readable text of an OpenUI block, for Read aloud, Share, Copy and fork
// summaries: titles, labels, values and text in order; never the DSL,
// URLs, ids, enum settings or actions.

import 'lang/ast.dart';
import 'lang/builtins.dart' show jsString;
import 'lang/evaluator.dart';
import 'lang/parser.dart';
import 'library.dart';
import 'openui_block.dart' show ouiChartData;

/// Props that never carry readable content.
const _skipProps = {
  'src',
  'alt',
  'image',
  'images',
  'url',
  'action',
  'language',
  'tone',
  'state',
  'kind',
  'gap',
  'size',
  'columns',
  'open',
  'primary',
  'numbered',
  'trend',
  'min',
  'max',
  'step',
  // OpenUI chat library settings
  'variant',
  'type',
  'direction',
  'layout',
  'responsive',
  'id',
  'iconVariant',
  'iconSize',
  'bold',
  'imageSize',
  'subtextVariant',
  'rightVariant',
  'mode',
  'rules',
  'height',
  'appearance',
  'orientation',
  'decorative',
  'isFoldable',
  'shape',
  'category',
  'bgColor',
  'bgImageSrc',
  'bgImageAlt',
  'disabled',
  'defaultChecked',
  'defaultValue',
  'visible',
  'icon',
  'file',
  'sources',
  'actionLabel',
  'ask',
  'cc',
};

/// Components whose `value` is an id, not text.
const _idValue = {
  'TabItem',
  'AccordionItem',
  'SectionItem',
  'SelectItem',
  'RadioItem',
  'ChipItem',
  'OptionCard',
};

/// Components whose `name` is a field or icon name, not text.
const _idName = {
  'Form',
  'Input',
  'TextArea',
  'Select',
  'DatePicker',
  'Slider',
  'CheckBoxGroup',
  'CheckBoxItem',
  'RadioGroup',
  'SwitchGroup',
  'SwitchItem',
  'Chips',
  'OptionCards',
  'Icon',
};

const _charts = {
  'BarChart',
  'LineChart',
  'AreaChart',
  'HorizontalBarChart',
  'RadarChart',
  'PieChart',
  'RadialChart',
  'SingleStackedBarChart',
  'ScatterChart',
};

/// Read aloud skips these entirely (follow-ups are offered, not read).
const _silent = {'FollowUpBlock', 'FollowUpItem', 'Icon', 'Separator'};

String openUiPlainText(String source) {
  try {
    final legacy = isLegacyProgram(source);
    final r = parseProgram(source, legacy ? legacyLibrary : toveLibrary);
    final ctx = EvaluationContext(
      getState: (n) => r.stateDeclarations[n],
      resolveRef: (_) => null,
      actions: toveActions,
      budget: EvalBudget(20000),
    );
    final root = evaluateRoot(r, ctx, legacy ? legacyBindings : toveBindings);
    if (root == null) return 'Interactive content.';
    final lines = <String>[];

    void scalarParts(Object? x, List<String> parts) {
      if (x is String || x is num) {
        final t = jsString(x).trim();
        if (t.isNotEmpty && !t.startsWith('entity:') && !t.startsWith('http')) {
          parts.add(t);
        }
      }
    }

    void walk(Object? v, [int depth = 0]) {
      if (depth > 40 || lines.length > 400) return;
      if (v is ElementNode) {
        final type = v.typeName;
        if (_silent.contains(type)) return;
        if (!legacy && _charts.contains(type)) {
          final d = ouiChartData(v);
          if (!d.isEmpty) lines.add('${d.kindLabel}: ${d.plainText}');
          return;
        }
        if (type == 'Email') {
          final to = (v.props['to'] is List ? v.props['to']! as List : const [])
              .map(jsString)
              .join(', ');
          lines.add(
            [
              'Email${to.isEmpty ? '' : ' to $to'}',
              if (v.props['subject'] != null)
                'Subject: ${jsString(v.props['subject'])}',
              if (v.props['body'] != null) jsString(v.props['body']),
            ].join('\n'),
          );
          return;
        }
        if (type == 'Artifact') {
          lines.add(
            '${jsString(v.props['title'] ?? 'Untitled')} '
            '(${jsString(v.props['kind'] ?? 'code')})',
          );
          return;
        }
        if (!legacy && type == 'Table') {
          final cols = [
            for (final c
                in (v.props['columns'] is List
                    ? v.props['columns']! as List
                    : const []))
              if (c is ElementNode) c,
          ];
          List<String> data(ElementNode c) => [
            for (final x
                in (c.props['data'] is List
                    ? c.props['data']! as List
                    : const []))
              jsString(x).trim(),
          ];
          lines.add(
            cols.map((c) => jsString(c.props['label'] ?? '')).join(', '),
          );
          final n = cols.fold<int>(
            0,
            (m, c) => data(c).length > m ? data(c).length : m,
          );
          for (var i = 0; i < n && i < 60; i++) {
            final cells = [
              for (final c in cols) i < data(c).length ? data(c)[i] : '',
            ];
            lines.add(
              cells.length > 1
                  ? '${cells.first}: ${cells.skip(1).join(', ')}'
                  : cells.first,
            );
          }
          return;
        }
        if (type == 'ChecklistSection') {
          final title = jsString(v.props['title'] ?? '').trim();
          final time = v.props['time'] == null
              ? ''
              : ' (${jsString(v.props['time'])})';
          final items =
              (v.props['items'] is List ? v.props['items']! as List : const [])
                  .map(jsString)
                  .join(', ');
          lines.add('$title$time: $items');
          return;
        }
        final parts = <String>[];
        final nested = <Object?>[];
        for (final e in v.props.entries) {
          if (_skipProps.contains(e.key)) continue;
          if (e.key == 'value' && _idValue.contains(type)) continue;
          if (e.key == 'name' && _idName.contains(type)) continue;
          if (legacy && e.key == 'values') continue;
          final x = e.value;
          if (x is String || x is num) {
            scalarParts(x, parts);
          } else if (x is List && x.every((i) => i is String || i is num)) {
            final items = <String>[];
            for (final i in x) {
              scalarParts(i, items);
            }
            if (items.isNotEmpty) parts.add(items.join(', '));
          } else if (x is List && x.every((i) => i is List)) {
            for (final row in x) {
              parts.add((row as List).map(jsString).join(', '));
            }
          } else if (x is List && x.isNotEmpty && x.every((i) => i is Map)) {
            // EntityList rows and similar records: "left: right".
            for (final m in x.cast<Map>()) {
              final vals = <String>[];
              for (final me in m.entries) {
                if (_skipProps.contains(me.key)) continue;
                scalarParts(me.value, vals);
              }
              if (vals.isNotEmpty) lines.add(vals.join(': '));
            }
          } else if (x is Map) {
            final vals = <String>[];
            for (final me in x.entries) {
              if (_skipProps.contains(me.key)) continue;
              if (me.value is ElementNode) {
                nested.add(me.value);
              } else {
                scalarParts(me.value, vals);
              }
            }
            if (vals.isNotEmpty) nested.add(vals.join(': '));
          } else {
            nested.add(x);
          }
        }
        if (parts.isNotEmpty) lines.add(parts.join(': '));
        for (final n in nested) {
          if (n is String) {
            lines.add(n);
          } else {
            walk(n, depth + 1);
          }
        }
      } else if (v is List) {
        for (final x in v) {
          walk(x, depth + 1);
        }
      }
    }

    walk(root);
    return lines.isEmpty ? 'Interactive content.' : lines.join('\n');
  } catch (_) {
    return 'Interactive content.';
  }
}

/// The FollowUpItem texts of an OpenUI program (at most 3), shown as
/// Tove's suggestions under the reply.
List<String> openUiFollowUps(String source) {
  try {
    if (!source.contains('FollowUp')) return const [];
    final r = parseProgram(source, toveLibrary);
    final ctx = EvaluationContext(
      getState: (n) => r.stateDeclarations[n],
      resolveRef: (_) => null,
      actions: toveActions,
      budget: EvalBudget(20000),
    );
    final root = evaluateRoot(r, ctx, toveBindings);
    final out = <String>[];
    void walk(Object? v, int depth) {
      if (depth > 40 || out.length >= 3) return;
      if (v is ElementNode) {
        if (v.typeName == 'FollowUpItem') {
          final t = jsString(v.props['text'] ?? '').trim();
          if (t.isNotEmpty) out.add(t.length > 120 ? t.substring(0, 120) : t);
          return;
        }
        for (final x in v.props.values) {
          walk(x, depth + 1);
        }
      } else if (v is List) {
        for (final x in v) {
          walk(x, depth + 1);
        }
      }
    }

    walk(root, 0);
    return out;
  } catch (_) {
    return const [];
  }
}
