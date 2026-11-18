// Input validation rules (language.md §5.4).
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// utils/validation.ts.

import 'syntax.dart' show jsNumberToString;

class ParsedRule {
  const ParsedRule(this.type, [this.arg]);
  final String type;
  final Object? arg;
}

/// `{required: true, maxLength: 80}` → rules, in key order.
List<ParsedRule> parseStructuredRules(Object? rules) {
  if (rules is! Map) return const [];
  return [
    for (final e in rules.entries)
      if (e.value != null && e.value != false)
        e.value == true ? ParsedRule('${e.key}') : ParsedRule('${e.key}', e.value),
  ];
}

bool _isEmpty(Object? v) {
  if (v == null || v == '') return true;
  if (v is List) return v.isEmpty;
  if (v is Map) {
    if (v.containsKey('value')) return _isEmpty(v['value']);
    return v.isEmpty;
  }
  return false;
}

/// JS `parseFloat`: the longest numeric prefix, NaN when none.
double _parseFloat(String s) {
  final m = RegExp(r'^\s*[+-]?(Infinity|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)')
      .firstMatch(s);
  if (m == null) return double.nan;
  final t = m[0]!.trim();
  if (t.endsWith('Infinity')) {
    return t.startsWith('-') ? double.negativeInfinity : double.infinity;
  }
  return double.tryParse(t) ?? double.nan;
}

double _num(Object? arg) => arg is num
    ? arg.toDouble()
    : double.tryParse('$arg'.trim()) ?? double.nan;

bool _isUrl(String v) {
  final u = Uri.tryParse(v);
  return u != null && u.hasScheme && u.scheme.isNotEmpty && (u.hasAuthority || u.path.isNotEmpty) &&
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(v) &&
      (u.host.isNotEmpty || !v.contains('//'));
}

String? _check(String type, Object? value, Object? arg) {
  switch (type) {
    case 'required':
      if (_isEmpty(value)) return 'This field is required';
      if (value is Map && value.isNotEmpty && value.values.every((v) => v is bool) &&
          !value.values.any((v) => v == true)) {
        return 'At least one option is required';
      }
      return null;
    case 'email':
      if (_isEmpty(value)) return null;
      if (value is! String) return 'Please enter a valid email';
      return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)
          ? null
          : 'Please enter a valid email';
    case 'url':
      if (_isEmpty(value)) return null;
      if (value is! String || !_isUrl(value)) return 'Please enter a valid URL';
      return null;
    case 'numeric':
      if (_isEmpty(value)) return null;
      if (value is num && !value.isNaN) return null;
      if (value is String && !_parseFloat(value).isNaN && value.trim().isNotEmpty) {
        return null;
      }
      return 'Must be a number';
    case 'min':
    case 'max':
      if (_isEmpty(value)) return null;
      final n = value is num ? value.toDouble() : _parseFloat('$value');
      if (n.isNaN) return null;
      final lim = _num(arg);
      if (type == 'min') {
        return n >= lim ? null : 'Must be at least ${jsNumberToString(lim)}';
      }
      return n <= lim ? null : 'Must be no more than ${jsNumberToString(lim)}';
    case 'minLength':
    case 'maxLength':
      if (_isEmpty(value) || value is! String) return null;
      final lim = _num(arg);
      if (type == 'minLength') {
        return value.length >= lim
            ? null
            : 'Must be at least ${jsNumberToString(lim)} characters';
      }
      return value.length <= lim
          ? null
          : 'Must be no more than ${jsNumberToString(lim)} characters';
    case 'pattern':
      if (_isEmpty(value) || value is! String || arg is! String) return null;
      try {
        return RegExp(arg).hasMatch(value) ? null : 'Invalid format';
      } catch (_) {
        return null;
      }
  }
  return null; // unknown rule: ignored
}

/// The first failing rule's message, or null when [value] passes.
String? validateRules(Object? value, List<ParsedRule> rules) {
  for (final r in rules) {
    final e = _check(r.type, value, r.arg);
    if (e != null) return e;
  }
  return null;
}
