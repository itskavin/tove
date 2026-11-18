// Runs the OpenUI Lang 1.0 conformance fixtures (level 1: program and
// validation cases) against the Dart port. The fixtures are vendored from
// thesysdev/openui spec/fixtures/1.0 (MIT, see fixtures/LICENSE-openui).
// Port of packages/lang-core/src/__tests__/conformance.test.ts.
//
// Not covered: editing cases (incremental edit merge is not ported) and the
// serialize half of `*-roundtrip-*` cases (serialization is not ported).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/openui/lang/ast.dart';
import 'package:tove_chat/src/ui/openui/lang/builtins.dart';
import 'package:tove_chat/src/ui/openui/lang/evaluator.dart';
import 'package:tove_chat/src/ui/openui/lang/parser.dart';
import 'package:tove_chat/src/ui/openui/lang/rules.dart';

const _dir = 'test/openui/fixtures/1.0';

class _Bindable implements SchemaContext {
  _Bindable(this.props);
  final Map<String, Set<String>> props;
  @override
  bool isReactive(String component, String prop) =>
      props[component]?.contains(prop) ?? false;
}

late final Map<String, Object?> _spec;
late final CompiledLibrary _lib;
late final _Bindable _schema;
late final Map<String, RuntimeFunction> _functions;
late final Map<String, Map<String, Object?>> _actions;

void _load() {
  _spec = (jsonDecode(File('$_dir/library.json').readAsStringSync()) as Map)
      .cast<String, Object?>();
  final schema = (_spec['schema']! as Map).cast<String, Object?>();
  _lib = compileSchema(schema, root: _spec['root'] as String?);
  final comps = (_spec['components'] as Map).cast<String, Object?>();
  _schema = _Bindable({
    for (final e in comps.entries)
      e.key: RegExp(r'(\w+)\??: \$binding<')
          .allMatches('${(e.value! as Map)['signature']}')
          .map((m) => m[1]!)
          .toSet(),
  });
  final fns = (schema['functions'] as Map?)?.cast<String, Object?>() ?? {};
  _functions = {
    for (final e in fns.entries)
      e.key: RuntimeFunction(
        params: ((e.value! as Map)['params'] as Map).cast<String, Object?>(),
        returns: ((e.value! as Map)['returns'] as Map?)?.cast<String, Object?>(),
        fn: switch (e.key) {
          'Upper' => (a) => jsString(a['text'] ?? '').toUpperCase(),
          _ => (_) => null,
        },
      ),
  };
  _actions = {
    for (final e in ((schema['actions'] as Map?) ?? {}).entries)
      '${e.key}': (e.value as Map).cast<String, Object?>(),
  };
}

Object? _summarizeStep(ActionStep s, EvaluationContext ctx) => switch (s) {
  ToAssistantStep() => {
    'action': 'ToAssistant',
    'args': [s.message, if (s.context != null) _summarize(s.context, ctx)],
  },
  OpenUrlStep() => {'action': 'OpenUrl', 'args': [s.url]},
  SetStep() => {
    'action': 'Set',
    'args': [s.target, _summarize(evaluate(s.valueAst, ctx), ctx)],
  },
  ResetStep() => {'action': 'Reset', 'args': s.targets},
  RunStep() => {'action': 'Run', 'args': [s.statementId]},
  CustomStep() => {
    'action': s.name,
    'args': [
      for (final k
          in ((_actions[s.name]?['params'] as Map?)?['properties'] as Map?)
                  ?.keys ??
              s.params.keys)
        _summarize(s.params[k], ctx),
    ],
  },
};

Object? _summarize(Object? v, EvaluationContext ctx) {
  if (v == null || v is Undefined) return null;
  if (v is num) return v.toDouble();
  if (v is String || v is bool) return v;
  if (v is List) return [for (final x in v) _summarize(x, ctx)];
  if (v is ElementNode) {
    return {
      'type': v.typeName,
      'props': {
        for (final e in v.props.entries)
          e.key: ?_summarize(e.value, ctx),
      },
    };
  }
  if (v is ActionPlan) {
    return {
      'actions': [for (final s in v.steps) _summarizeStep(s, ctx)],
    };
  }
  if (v is ReactiveAssign) return {r'$binding': v.target};
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': _summarize(e.value, ctx)};
  }
  return '$v';
}

/// JSON with every number as a double, for comparison.
Object? _norm(Object? v) => switch (v) {
  num() => v.toDouble(),
  List() => [for (final x in v) _norm(x)],
  // Key order is not significant (Node's isDeepStrictEqual ignores it).
  Map() => {
    for (final k in v.keys.map((k) => '$k').toList()..sort()) k: _norm(v[k]),
  },
  _ => v,
};

bool _same(Object? a, Object? b) =>
    jsonEncode(_norm(a)) == jsonEncode(_norm(b));

Map<String, Object?> _evaluateResult(ParseResult r) {
  final state = Map<String, Object?>.of(r.stateDeclarations);
  late final EvaluationContext ctx;
  ctx = EvaluationContext(
    getState: (n) => state[n],
    resolveRef: (name) {
      for (final q in r.queryStatements) {
        if (q.statementId == name) {
          return q.defaultsAst == null ? null : evaluate(q.defaultsAst!, ctx);
        }
      }
      if (r.mutationStatements.any((m) => m.statementId == name)) {
        return {'status': 'idle', 'data': null, 'error': null};
      }
      return null;
    },
    functions: _functions,
    actions: _actions,
  );
  final runtime = <OpenUiError>[];
  final tree = evaluateRoot(r, ctx, _schema, runtime);
  final errors = [...r.meta.errors, ...runtime];
  return {
    'root': _summarize(tree, ctx),
    'errors': [
      for (final e in errors) {'code': e.code, 'statementId': e.statementId},
    ],
    'errorObjects': [
      for (final e in errors)
        {
          'source': e.source,
          'code': e.code,
          'statementId': e.statementId,
          'component': e.component,
          'path': e.path.isEmpty ? null : e.path,
        },
    ],
    'unresolved': r.meta.unresolved,
    'orphans': r.meta.orphaned,
    'incomplete': r.meta.incomplete,
    'state': _summarize(r.stateDeclarations, ctx),
  };
}

bool _claims(List expected, List actual) {
  final pool = [...actual.cast<Map>()];
  final exp = [...expected.cast<Map>()]
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final e in exp) {
    final i = pool.indexWhere(
      (a) => e.entries.every((kv) => _same(kv.value, a[kv.key])),
    );
    if (i < 0) return false;
    pool.removeAt(i);
  }
  return true;
}

List<String> _check(Map expected, ParseResult r) {
  final got = _evaluateResult(r);
  final diffs = <String>[];
  void diff(String k) => diffs.add(
    '$k: expected ${jsonEncode(expected[k])}, got ${jsonEncode(got[k])}',
  );
  Set<Object?> asSet(Object? v) => {...(v as List? ?? const [])};
  if (!_same(expected['root'], got['root'])) diff('root');
  final we = expected['errors'] as List;
  final ge = got['errors']! as List;
  if (we.length != ge.length || !_claims(we, ge)) diff('errors');
  if (!asSet(expected['unresolved']).containsAll(asSet(got['unresolved'])) ||
      !asSet(got['unresolved']).containsAll(asSet(expected['unresolved']))) {
    diff('unresolved');
  }
  if (!asSet(expected['orphans']).containsAll(asSet(got['orphans'])) ||
      !asSet(got['orphans']).containsAll(asSet(expected['orphans']))) {
    diff('orphans');
  }
  if (expected['incomplete'] != got['incomplete']) diff('incomplete');
  if (expected.containsKey('state') && !_same(expected['state'], got['state'])) {
    diff('state');
  }
  if (expected.containsKey('errorObjects') &&
      !_claims(expected['errorObjects'] as List, got['errorObjects']! as List)) {
    diff('errorObjects');
  }
  return diffs;
}

void main() {
  _load();
  final areas = Directory(_dir).listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final area in areas) {
    final cases = area.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final c in cases) {
      final id = c.path.substring(_dir.length + 1);
      String? read(String f) {
        final file = File('${c.path}/$f');
        return file.existsSync() ? file.readAsStringSync() : null;
      }

      final skip = read('patch.oui') != null
          ? 'edit merge is not ported'
          : null;
      test(id, skip: skip, () {
        final validation = read('validation.json');
        if (validation != null) {
          final cases = (jsonDecode(validation) as Map)['cases'] as List;
          final fails = <String>[];
          for (final (i, v) in cases.indexed) {
            final m = v as Map;
            final err = validateRules(m['value'], parseStructuredRules(m['rules']));
            if ((err == null) != m['valid']) {
              fails.add('case $i ${jsonEncode(m)}: got $err');
            }
          }
          expect(fails, isEmpty, reason: fails.join('\n'));
          return;
        }
        final expected = jsonDecode(read('expected.json')!) as Map;
        final chunks = read('chunks.json');
        final diffs = <String>[];
        if (chunks != null) {
          final list = (jsonDecode(chunks) as List).cast<String>();
          final p = StreamParser(_lib);
          ParseResult? last;
          for (final (i, ch) in list.indexed) {
            last = p.push(ch, complete: i == list.length - 1);
          }
          diffs
            ..addAll(_check(expected, last!).map((d) => 'streamed $d'))
            ..addAll(
              _check(expected, parseProgram(list.join(), _lib))
                  .map((d) => 'batch $d'),
            );
        } else {
          diffs.addAll(_check(expected, parseProgram(read('input.oui')!, _lib)));
        }
        expect(diffs, isEmpty, reason: '$id\n  ${diffs.join('\n  ')}');
      });
    }
  }
}
