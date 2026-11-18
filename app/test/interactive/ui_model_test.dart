import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/interactive/format.dart';
import 'package:tove_chat/src/ui/interactive/suggestions.dart';
import 'package:tove_chat/src/ui/interactive/ui_model.dart';

void main() {
  UiElement ok(Object json) {
    final r = parseHermesUi(jsonEncode(json));
    expect(r.error, isNull);
    return r.element!;
  }

  String fails(Object json) {
    final r = parseHermesUi(json is String ? json : jsonEncode(json));
    expect(r.ok, isFalse, reason: '$json');
    return r.error!;
  }

  group('parser', () {
    test('every element type from the spec parses', () {
      final o = ok({
        'v': 1,
        'type': 'options',
        'id': 'use-case',
        'prompt': 'What are you building?',
        'select': 'one',
        'options': [
          {'label': 'Voice companion', 'send': 'I am building a companion.'},
          {'label': 'Both'},
        ],
        'other': true,
      }) as UiOptions;
      expect(o.many, isFalse);
      expect(o.other, isTrue);
      expect(o.options.last.send, 'Both');

      final a = ok({
        'v': 1,
        'type': 'actions',
        'items': [
          {
            'label': 'Run',
            'style': 'primary',
            'action': {'send': 'Run it.'},
          },
          {
            'label': 'Docs',
            'action': {'link': 'https://example.com/x'},
          },
          {
            'label': 'Copy',
            'action': {'copy': 'df -h'},
          },
        ],
      }) as UiActions;
      expect(a.items.first.primary, isTrue);
      expect(a.items[1].action.link, 'https://example.com/x');
      expect(a.items[2].action.copy, 'df -h');

      final c = ok({
        'v': 1,
        'type': 'cards',
        'items': [
          {'label': 'Cost', 'value': r'$3.00', 'sub': 'Base', 'tone': 'good'},
        ],
      }) as UiCards;
      expect(c.items.single.tone, UiTone.good);

      final calc = ok({
        'v': 1,
        'type': 'calc',
        'id': 'cost',
        'inputs': [
          {
            'id': 'minutes',
            'kind': 'slider',
            'label': 'Session length',
            'min': 10,
            'max': 600,
            'step': 10,
            'value': 60,
            'format': '{} minutes',
          },
          {'id': 'tools', 'kind': 'toggle', 'label': 'Tools', 'value': true},
          {
            'id': 'tier',
            'kind': 'segmented',
            'label': 'Tier',
            'value': 2,
            'options': [
              {'label': 'Mini', 'value': 1},
              {'label': 'Full', 'value': 2},
            ],
          },
        ],
        'outputs': [
          {
            'label': 'Base',
            'expr': 'minutes * 0.05 * tier * (tools ? 1.4 : 1)',
            'format': 'currency:USD',
          },
        ],
      }) as UiCalc;
      expect(calc.inputs[1].value, 1);
      expect(
        calc.outputs.single.expr.eval({'minutes': 60, 'tools': 0, 'tier': 1}),
        closeTo(3, 1e-9),
      );

      expect(
        ok({'v': 1, 'type': 'details', 'title': 'Method', 'body': '**b**'}),
        isA<UiDetails>(),
      );
      final callout = ok({
        'v': 1,
        'type': 'callout',
        'tone': 'warning',
        'title': 'Backups paused',
        'body': 'Until Sunday.',
      }) as UiCallout;
      expect(callout.tone, UiTone.warn);
      expect(
        (ok({
          'v': 1,
          'type': 'suggestions',
          'items': ['One', 'Two'],
        }) as UiSuggestions).items,
        ['One', 'Two'],
      );
      final g = ok({
        'v': 1,
        'type': 'group',
        'title': 'Cost comparison',
        'children': [
          {'type': 'callout', 'body': 'x'},
          {
            'type': 'cards',
            'items': [
              {'label': 'a', 'value': '1'},
            ],
          },
        ],
      }) as UiGroup;
      expect(g.children, hasLength(2));
    });

    test('invalid JSON, versions and unknown types fail', () {
      expect(fails('{"v":1,"type":"options"'), startsWith('invalid JSON'));
      expect(fails('[1,2]'), contains('object'));
      expect(fails({'type': 'cards'}), contains('"v"'));
      expect(
        fails({'v': 2, 'type': 'cards', 'items': []}),
        contains('version'),
      );
      expect(fails({'v': 1, 'type': 'iframe'}), contains('unknown type'));
      expect(fails({'v': 1}), contains('type'));
    });

    test('limits are enforced', () {
      // Size.
      expect(
        fails({
          'v': 1,
          'type': 'callout',
          'body': 'x' * 900,
          'title': 'y' * 40,
          'pad': 'z' * 16000,
        }),
        contains('16 KB'),
      );
      // Labels (60) and strings (300).
      fails({
        'v': 1,
        'type': 'cards',
        'items': [
          {'label': 'x' * 61, 'value': '1'},
        ],
      });
      fails({
        'v': 1,
        'type': 'options',
        'prompt': 'p' * 301,
        'options': [
          {'label': 'a'},
          {'label': 'b'},
        ],
      });
      // Counts.
      fails({
        'v': 1,
        'type': 'options',
        'options': [
          {'label': 'a'},
        ],
      });
      fails({
        'v': 1,
        'type': 'actions',
        'items': List.filled(4, {
          'label': 'a',
          'action': {'copy': 'x'},
        }),
      });
      // Elements (24) and depth (a group inside a group).
      expect(
        fails({
          'v': 1,
          'type': 'group',
          'children': List.filled(24, {'type': 'callout', 'body': 'x'}),
        }),
        contains('24 elements'),
      );
      expect(
        fails({
          'v': 1,
          'type': 'group',
          'children': [
            {
              'type': 'group',
              'children': [
                {'type': 'callout', 'body': 'x'},
              ],
            },
          ],
        }),
        contains('nested'),
      );
    });

    test('actions allow only send, safe links and copy', () {
      for (final link in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'data:text/html,hi',
        'intent://x',
        '/relative',
      ]) {
        fails({
          'v': 1,
          'type': 'actions',
          'items': [
            {
              'label': 'x',
              'action': {'link': link},
            },
          ],
        });
      }
      fails({
        'v': 1,
        'type': 'actions',
        'items': [
          {
            'label': 'x',
            'action': {'eval': '1'},
          },
        ],
      });
      fails({
        'v': 1,
        'type': 'actions',
        'items': [
          {
            'label': 'x',
            'action': {'send': 'a', 'copy': 'b'},
          },
        ],
      });
      ok({
        'v': 1,
        'type': 'actions',
        'items': [
          {
            'label': 'Mail',
            'action': {'link': 'mailto:a@b.c'},
          },
        ],
      });
    });

    test('calc expressions are checked against the input ids', () {
      expect(
        fails({
          'v': 1,
          'type': 'calc',
          'inputs': [
            {'id': 'a', 'label': 'A', 'min': 0, 'max': 1},
          ],
          'outputs': [
            {'label': 'x', 'expr': 'b * 2'},
          ],
        }),
        contains('unknown input'),
      );
      fails({
        'v': 1,
        'type': 'calc',
        'inputs': [
          {'id': 'a', 'label': 'A', 'min': 5, 'max': 1},
        ],
        'outputs': [
          {'label': 'x', 'expr': 'a'},
        ],
      });
      fails({
        'v': 1,
        'type': 'calc',
        'inputs': [
          {'id': 'BAD ID', 'label': 'A', 'min': 0, 'max': 1},
        ],
        'outputs': [
          {'label': 'x', 'expr': '1'},
        ],
      });
    });

    test('tones never carry colours', () {
      fails({'v': 1, 'type': 'callout', 'tone': '#ff0000', 'body': 'x'});
    });

    test('streaming helpers', () {
      expect(looksIncompleteJson('{"v":1,"type":"opt'), isTrue);
      expect(looksIncompleteJson('{"v":1,"items":[{"a":"}"}'), isTrue);
      expect(looksIncompleteJson(''), isTrue);
      expect(looksIncompleteJson('{"v":1}'), isFalse);
      expect(looksIncompleteJson('{"v":1}}'), isFalse);
      expect(peekUiType('{"v":1,"type":"calc","inp'), 'calc');
      expect(peekUiType('{"v":1,"ty'), isNull);
    });
  });

  group('formats', () {
    test('formats values', () {
      expect(formatUiValue(60, '{} minutes'), '60 minutes');
      expect(formatUiValue(2.5, '{} h'), '2.5 h');
      expect(formatUiValue(3, 'currency:USD'), r'$3.00');
      expect(formatUiValue(23.5, 'currency:USD'), r'$23.50');
      expect(formatUiValue(1234567.891, 'currency:EUR'), '€1,234,567.89');
      expect(formatUiValue(-4, 'currency:GBP'), '−£4.00');
      expect(formatUiValue(1500, 'currency:JPY'), '¥1,500');
      expect(formatUiValue(9, 'currency:XYZ'), 'XYZ 9.00');
      expect(formatUiValue(0.256, 'percent:1'), '25.6%');
      expect(formatUiValue(12345.678, 'number:2'), '12,345.68');
      expect(formatUiValue(190, 'duration:min'), '3 h 10 min');
      expect(formatUiValue(45, 'duration:min'), '45 min');
      expect(formatUiValue(120, 'duration:min'), '2 h');
      expect(formatUiValue(null, 'currency:USD'), '—');
      expect(formatUiValue(double.nan, null), '—');
      expect(formatUiValue(-0.001, 'number:2'), '0.00');
    });
  });

  group('message helpers', () {
    const reply = '''Intro.

```hermes-ui
{"v":1,"type":"options","prompt":"Pick","options":[{"label":"A"},{"label":"B"}]}
```

```hermes-ui
{"v":1,"type":"suggestions","items":["Tell me more","Compare costs"]}
```
''';

    test('extractSuggestions lifts the last suggestions block', () {
      expect(extractSuggestions(reply), ['Tell me more', 'Compare costs']);
      expect(extractSuggestions('No blocks.'), isEmpty);
    });

    test('hermesUiPlainText never reads JSON aloud', () {
      final t = hermesUiPlainText(reply);
      expect(t, contains('Pick\nA, B'));
      expect(t, isNot(contains('{')));
      expect(
        hermesUiPlainText('```hermes-ui\n{"v":1,\n```'),
        'Interactive content.',
      );
    });
  });
}
