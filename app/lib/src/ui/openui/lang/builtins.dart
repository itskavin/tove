// Built-in functions and action steps, plus the JavaScript value semantics
// OpenUI Lang requires (language.md §3.1).
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// parser/builtins.ts.

import 'dart:math' as math;

import 'ast.dart';
import 'syntax.dart' show jsNumberToString;

// ─── JS value semantics ───────────────────────────────────────────────────

/// ECMAScript ToNumber, with NaN mapped to 0 (spec §3.1).
double toNumber(Object? v) {
  if (v is num) return v.isNaN ? 0 : v.toDouble();
  if (v is bool) return v ? 1 : 0;
  if (v is String) {
    final n = _stringToNumber(v);
    return n.isNaN ? 0 : n;
  }
  return 0;
}

double _stringToNumber(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  final lower = t.toLowerCase();
  if (lower.startsWith('0x') || lower.startsWith('0o') || lower.startsWith('0b')) {
    final radix = switch (lower[1]) { 'x' => 16, 'o' => 8, _ => 2 };
    final n = int.tryParse(t.substring(2), radix: radix);
    return n?.toDouble() ?? double.nan;
  }
  if (t == 'Infinity' || t == '+Infinity') return double.infinity;
  if (t == '-Infinity') return double.negativeInfinity;
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(t)) {
    return double.nan;
  }
  return double.tryParse(t) ?? double.nan;
}

/// True when [s] parses fully as a number (JS `!isNaN(Number(s)) && s !== ""`).
bool isNumericString(String s) => s != '' && !_stringToNumber(s).isNaN;

/// ECMAScript ToBoolean.
bool truthy(Object? v) {
  if (v == null || v is Undefined) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// ECMAScript ToString for runtime values.
String jsString(Object? v) {
  if (v == null) return 'null';
  if (v is Undefined) return 'undefined';
  if (v is String) return v;
  if (v is num) return jsNumberToString(v);
  if (v is bool) return v ? 'true' : 'false';
  if (v is List) {
    return v.map((e) => e == null || e is Undefined ? '' : jsString(e)).join(',');
  }
  return '[object Object]';
}

/// ECMAScript IsLooselyEqual (`==`).
bool looseEquals(Object? a, Object? b) {
  if (a is Undefined) a = null;
  if (b is Undefined) b = null;
  if (a == null || b == null) return a == null && b == null;
  if (a is num && b is num) return a == b;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  if (a is bool) return looseEquals(a ? 1.0 : 0.0, b);
  if (b is bool) return looseEquals(a, b ? 1.0 : 0.0);
  if (a is num && b is String) return a == _stringToNumber(b);
  if (a is String && b is num) return _stringToNumber(a) == b;
  final aObj = a is List || a is Map || a is ElementNode;
  final bObj = b is List || b is Map || b is ElementNode;
  if (aObj && bObj) return identical(a, b);
  // Object vs primitive: ToPrimitive(object) is its string form.
  if (aObj) return looseEquals(jsString(a), b);
  if (bObj) return looseEquals(a, jsString(b));
  return false;
}

/// `localeCompare` with no arguments (ICU root collation), close enough for
/// sorting labels: base letters first (accents and case ignored), then
/// accents, then lower case before upper case.
int localeCompare(String a, String b) {
  final c1 = _fold(a).compareTo(_fold(b));
  if (c1 != 0) return c1;
  final c2 = a.toLowerCase().compareTo(b.toLowerCase());
  if (c2 != 0) return c2;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] == b[i]) continue;
    return a[i] == a[i].toLowerCase() ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}

const _accents = {
  'a': 'àáâãäåāăą',
  'c': 'çćĉċč',
  'd': 'ďđ',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğġģ',
  'h': 'ĥħ',
  'i': 'ìíîïĩīĭįı',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľŀł',
  'n': 'ñńņňŉ',
  'o': 'òóôõöøōŏő',
  'r': 'ŕŗř',
  's': 'śŝşšß',
  't': 'ţťŧ',
  'u': 'ùúûüũūŭůűų',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};

final Map<String, String> _baseOf = {
  for (final e in _accents.entries)
    for (final ch in e.value.split('')) ch: e.key,
};

/// Lower case with Latin accents removed: the primary collation key.
String _fold(String s) {
  final lower = s.toLowerCase();
  if (lower.codeUnits.every((c) => c < 0x80)) return lower;
  return lower.split('').map((ch) => _baseOf[ch] ?? ch).join();
}

/// JavaScript `Math.round`: halves round up.
double jsRound(double x) => (x + 0.5).floorToDouble();

Object? _field(Object? obj, String path) {
  if (path.isEmpty || obj == null) return undefined;
  Object? cur = obj;
  for (final p in path.split('.')) {
    if (cur == null) return undefined;
    cur = memberOf(cur, p);
  }
  return cur;
}

/// `obj[key]` on a runtime value.
Object? memberOf(Object? obj, String key) {
  if (obj is Map) return obj.containsKey(key) ? obj[key] : undefined;
  if (obj is List) {
    if (key == 'length') return obj.length.toDouble();
    final i = int.tryParse(key);
    return i != null && i >= 0 && i < obj.length ? obj[i] : undefined;
  }
  if (obj is String) {
    if (key == 'length') return obj.length.toDouble();
  }
  return undefined;
}

// ─── Call registry ────────────────────────────────────────────────────────

class ParamDef {
  const ParamDef({
    required this.name,
    this.required = false,
    this.defaultValue = undefined,
    this.schema,
  });
  final String name;
  final bool required;

  /// [undefined] when the schema has no default.
  final Object? defaultValue;

  /// The raw JSON Schema fragment.
  final Object? schema;
}

class CallDef {
  const CallDef({
    required this.kind,
    required this.params,
    this.builtin = false,
    this.lazy = false,
  });

  /// `function` or `action`.
  final String kind;
  final List<ParamDef> params;
  final bool builtin;
  final bool lazy;
}

List<ParamDef> _names(List<String> names) => [
  for (final n in names) ParamDef(name: n),
];

const _functionParams = <String, List<String>>{
  'Count': ['array'],
  'First': ['array'],
  'Last': ['array'],
  'Sum': ['numbers'],
  'Avg': ['numbers'],
  'Min': ['numbers'],
  'Max': ['numbers'],
  'Sort': ['array', 'field', 'direction'],
  'Filter': ['array', 'field', 'operator', 'value'],
  'Round': ['number', 'decimals'],
  'Abs': ['number'],
  'Floor': ['number'],
  'Ceil': ['number'],
  'Each': ['array', 'varName', 'template'],
};

const _stepParams = <String, List<String>>{
  'Run': ['ref'],
  'ToAssistant': ['message', 'context'],
  'OpenUrl': ['url'],
  'Set': ['variable', 'value'],
  'Reset': ['variable'],
};

const _lazy = {'Each', 'Run', 'Set', 'Reset', 'Action'};

/// The built-in functions, steps and Action.
final Map<String, CallDef> builtinCalls = {
  for (final e in _functionParams.entries)
    e.key: CallDef(
      kind: 'function',
      params: _names(e.value),
      builtin: true,
      lazy: _lazy.contains(e.key),
    ),
  for (final e in _stepParams.entries)
    e.key: CallDef(
      kind: 'action',
      params: _names(e.value),
      builtin: true,
      lazy: _lazy.contains(e.key),
    ),
  'Action': const CallDef(
    kind: 'action',
    params: [ParamDef(name: 'steps', required: true)],
    builtin: true,
    lazy: true,
  ),
};

bool isBuiltin(String name) => builtinCalls.containsKey(name);

bool isReservedCall(String name) => name == 'Query' || name == 'Mutation';

bool isBuiltinStep(String name) => builtinCalls[name]?.kind == 'action';

/// Built-in function names, in prompt order.
List<String> get builtinFunctionNames => _functionParams.keys.toList();

Object _elementwise(Object? v, double Function(double) f) => v is List
    ? [for (final x in v) _elementwise(x, f)]
    : f(toNumber(v));

double _sum(List l) => l.fold(0.0, (a, b) => a + toNumber(b));

/// Runs an eager built-in function with named args.
Object? runBuiltin(String name, Map<String, Object?> a) {
  switch (name) {
    case 'Count':
      final arr = a['array'];
      return arr is List ? arr.length.toDouble() : 0.0;
    case 'First':
      final arr = a['array'];
      return arr is List && arr.isNotEmpty ? arr.first : null;
    case 'Last':
      final arr = a['array'];
      return arr is List && arr.isNotEmpty ? arr.last : null;
    case 'Sum':
      final l = a['numbers'];
      return l is List ? _sum(l) : 0.0;
    case 'Avg':
      final l = a['numbers'];
      return l is List && l.isNotEmpty ? _sum(l) / l.length : 0.0;
    case 'Min':
    case 'Max':
      final l = a['numbers'];
      if (l is! List || l.isEmpty) return 0.0;
      var acc = toNumber(l.first);
      for (final x in l) {
        acc = name == 'Min'
            ? math.min(acc, toNumber(x))
            : math.max(acc, toNumber(x));
      }
      return acc;
    case 'Sort':
      final arr = a['array'];
      if (arr is! List) return arr;
      final f = a['field'] == null ? '' : jsString(a['field']);
      final desc = a['direction'] != null && jsString(a['direction']) == 'desc';
      bool numeric(Object? v) =>
          v is num || (v is String && isNumericString(v));
      final indexed = arr.indexed.toList();
      indexed.sort((x, y) {
        final av = f.isEmpty ? x.$2 : _field(x.$2, f);
        final bv = f.isEmpty ? y.$2 : _field(y.$2, f);
        int c;
        if (numeric(av) && numeric(bv)) {
          final d = toNumber(av) - toNumber(bv);
          c = d < 0 ? -1 : (d > 0 ? 1 : 0);
        } else {
          String str(Object? v) => v == null || v is Undefined ? '' : jsString(v);
          c = localeCompare(str(av), str(bv));
        }
        if (desc) c = -c;
        return c != 0 ? c : x.$1.compareTo(y.$1); // stable
      });
      return [for (final e in indexed) e.$2];
    case 'Filter':
      final arr = a['array'];
      if (arr is! List) return <Object?>[];
      final f = a['field'] == null ? '' : jsString(a['field']);
      final op = a['operator'] == null ? '==' : jsString(a['operator']);
      final value = a['value'];
      return [
        for (final item in arr)
          if (_filterMatch(f.isEmpty ? item : _field(item, f), op, value)) item,
      ];
    case 'Round':
      final d = a['decimals'] != null ? toNumber(a['decimals']) : 0.0;
      final factor = math.pow(10, d).toDouble();
      return _elementwise(a['number'], (n) => jsRound(n * factor) / factor);
    case 'Abs':
      return _elementwise(a['number'], (n) => n.abs());
    case 'Floor':
      return _elementwise(a['number'], (n) => n.floorToDouble());
    case 'Ceil':
      return _elementwise(a['number'], (n) => n.ceilToDouble());
  }
  return null;
}

bool _filterMatch(Object? v, String op, Object? value) => switch (op) {
  '==' => looseEquals(v, value),
  '!=' => !looseEquals(v, value),
  '>' => toNumber(v) > toNumber(value),
  '<' => toNumber(v) < toNumber(value),
  '>=' => toNumber(v) >= toNumber(value),
  '<=' => toNumber(v) <= toNumber(value),
  'contains' => (v == null || v is Undefined ? '' : jsString(v)).contains(
    value == null || value is Undefined ? '' : jsString(value),
  ),
  _ => false,
};
