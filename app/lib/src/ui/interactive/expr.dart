/// The tiny arithmetic language of hermes-ui `calc` outputs
/// (chat-rendering-v2 §3.4).
///
/// ```text
/// expr    := ternary
/// ternary := or ( "?" expr ":" expr )?
/// or      := and ( "||" and )*
/// and     := cmp ( "&&" cmp )*
/// cmp     := sum ( ("<"|"<="|">"|">="|"=="|"!=") sum )?
/// sum     := prod ( ("+"|"-") prod )*
/// prod    := unary ( ("*"|"/"|"%") unary )*
/// unary   := "-" unary | atom
/// atom    := NUMBER | IDENT | IDENT "(" expr ("," expr)* ")" | "(" expr ")"
/// ```
///
/// Identifiers are input ids. Functions: `min`, `max`, `round(x[, digits])`,
/// `floor`, `ceil`, `abs`, `clamp(x, lo, hi)`. Booleans are 1 and 0. Division
/// or modulo by zero, and any non-finite result, gives null (shown as "—").
/// No loops, strings, assignments or other calls exist, sources are capped at
/// [maxExprLength] characters and nesting at [maxExprDepth].
library;

import 'dart:math' as math;

const int maxExprLength = 200;
const int maxExprDepth = 24;

class ExprError implements Exception {
  ExprError(this.message, [this.position]);
  final String message;
  final int? position;

  @override
  String toString() =>
      'ExprError: $message${position == null ? '' : ' at $position'}';
}

/// A parsed expression. Evaluate it with [eval].
sealed class Expr {
  const Expr();

  /// The value for the given input values, or null when undefined.
  double? eval(Map<String, double> env);

  /// The identifiers this expression reads.
  Set<String> get identifiers {
    final out = <String>{};
    _collect(out);
    return out;
  }

  void _collect(Set<String> out);

  /// Parses [source], checking identifiers against [known] when given.
  static Expr parse(String source, {Set<String>? known}) {
    if (source.length > maxExprLength) {
      throw ExprError('longer than $maxExprLength characters');
    }
    final p = _Parser(_lex(source, known), known);
    final e = p.expr(0);
    p.expectEnd();
    return e;
  }
}

double? _finite(double v) => v.isFinite ? v : null;

class _Num extends Expr {
  const _Num(this.value);
  final double value;
  @override
  double? eval(Map<String, double> env) => value;
  @override
  void _collect(Set<String> out) {}
}

class _Ident extends Expr {
  const _Ident(this.name);
  final String name;
  @override
  double? eval(Map<String, double> env) => env[name];
  @override
  void _collect(Set<String> out) => out.add(name);
}

class _Neg extends Expr {
  const _Neg(this.a);
  final Expr a;
  @override
  double? eval(Map<String, double> env) {
    final v = a.eval(env);
    return v == null ? null : -v;
  }

  @override
  void _collect(Set<String> out) => a._collect(out);
}

class _Bin extends Expr {
  const _Bin(this.op, this.a, this.b);
  final String op;
  final Expr a, b;

  @override
  double? eval(Map<String, double> env) {
    // && and || short-circuit like their usual meaning; truth is != 0.
    if (op == '&&' || op == '||') {
      final x = a.eval(env);
      if (x == null) return null;
      if (op == '&&' && x == 0) return 0;
      if (op == '||' && x != 0) return 1;
      final y = b.eval(env);
      if (y == null) return null;
      return y != 0 ? 1 : 0;
    }
    final x = a.eval(env), y = b.eval(env);
    if (x == null || y == null) return null;
    double t(bool c) => c ? 1 : 0;
    return switch (op) {
      '+' => _finite(x + y),
      '-' => _finite(x - y),
      '*' => _finite(x * y),
      '/' => y == 0 ? null : _finite(x / y),
      '%' => y == 0 ? null : _finite(x % y),
      '<' => t(x < y),
      '<=' => t(x <= y),
      '>' => t(x > y),
      '>=' => t(x >= y),
      '==' => t(x == y),
      '!=' => t(x != y),
      _ => null,
    };
  }

  @override
  void _collect(Set<String> out) {
    a._collect(out);
    b._collect(out);
  }
}

class _Cond extends Expr {
  const _Cond(this.c, this.a, this.b);
  final Expr c, a, b;
  @override
  double? eval(Map<String, double> env) {
    final v = c.eval(env);
    if (v == null) return null;
    return v != 0 ? a.eval(env) : b.eval(env);
  }

  @override
  void _collect(Set<String> out) {
    c._collect(out);
    a._collect(out);
    b._collect(out);
  }
}

class _Call extends Expr {
  const _Call(this.name, this.args);
  final String name;
  final List<Expr> args;

  /// Allowed functions and their (min, max) argument counts.
  static const functions = <String, (int, int)>{
    'min': (1, 16),
    'max': (1, 16),
    'round': (1, 2),
    'floor': (1, 1),
    'ceil': (1, 1),
    'abs': (1, 1),
    'clamp': (3, 3),
  };

  @override
  double? eval(Map<String, double> env) {
    final v = <double>[];
    for (final a in args) {
      final x = a.eval(env);
      if (x == null) return null;
      v.add(x);
    }
    switch (name) {
      case 'min':
        return v.reduce(math.min);
      case 'max':
        return v.reduce(math.max);
      case 'round':
        final digits = v.length > 1 ? v[1].round().clamp(0, 8) : 0;
        final f = math.pow(10, digits).toDouble();
        return _finite((v[0] * f).roundToDouble() / f);
      case 'floor':
        return v[0].floorToDouble();
      case 'ceil':
        return v[0].ceilToDouble();
      case 'abs':
        return v[0].abs();
      case 'clamp':
        if (v[1] > v[2]) return null;
        return v[0].clamp(v[1], v[2]).toDouble();
    }
    return null;
  }

  @override
  void _collect(Set<String> out) {
    for (final a in args) {
      a._collect(out);
    }
  }
}

// ------------------------------------------------------------------ lexer

enum _T { num, ident, op, lparen, rparen, comma, question, colon, end }

class _Tok {
  const _Tok(this.type, this.text, this.pos);
  final _T type;
  final String text;
  final int pos;
}

final _numRe = RegExp(r'(\d+(\.\d*)?|\.\d+)');
final _identRe = RegExp(r'[A-Za-z_][A-Za-z0-9_]*(-[A-Za-z0-9_]+)*');
const _ops = [
  '<=',
  '>=',
  '==',
  '!=',
  '&&',
  '||',
  '<',
  '>',
  '+',
  '-',
  '*',
  '/',
  '%',
];

List<_Tok> _lex(String s, Set<String>? known) {
  final out = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    final n = _numRe.matchAsPrefix(s, i);
    if (n != null) {
      out.add(_Tok(_T.num, n[0]!, i));
      i = n.end;
      continue;
    }
    final id = _identRe.matchAsPrefix(s, i);
    if (id != null) {
      // Input ids may contain "-" ("use-case"), which is also minus: take
      // the longest hyphenated prefix that is a known id, else stop at the
      // first "-" ("a-b" is a minus b).
      final parts = id[0]!.split('-');
      var text = parts.first;
      for (var k = parts.length; k > 1; k--) {
        final cand = parts.sublist(0, k).join('-');
        if (known?.contains(cand) ?? false) {
          text = cand;
          break;
        }
      }
      out.add(_Tok(_T.ident, text, i));
      i += text.length;
      continue;
    }
    switch (c) {
      case '(':
        out.add(_Tok(_T.lparen, c, i++));
        continue;
      case ')':
        out.add(_Tok(_T.rparen, c, i++));
        continue;
      case ',':
        out.add(_Tok(_T.comma, c, i++));
        continue;
      case '?':
        out.add(_Tok(_T.question, c, i++));
        continue;
      case ':':
        out.add(_Tok(_T.colon, c, i++));
        continue;
    }
    final op = _ops.where((o) => s.startsWith(o, i)).firstOrNull;
    if (op == null) throw ExprError('unexpected "$c"', i);
    out.add(_Tok(_T.op, op, i));
    i += op.length;
  }
  out.add(_Tok(_T.end, '', s.length));
  return out;
}

// ----------------------------------------------------------------- parser

class _Parser {
  _Parser(this.toks, this.known);
  final List<_Tok> toks;
  final Set<String>? known;
  var i = 0;

  _Tok get peek => toks[i];
  _Tok next() => toks[i++];

  bool _isOp(String op) => peek.type == _T.op && peek.text == op;

  void _depth(int d) {
    if (d > maxExprDepth) throw ExprError('nested too deeply', peek.pos);
  }

  void expectEnd() {
    if (peek.type != _T.end) {
      throw ExprError('unexpected "${peek.text}"', peek.pos);
    }
  }

  Expr expr(int d) {
    _depth(d);
    final c = _or(d);
    if (peek.type == _T.question) {
      next();
      final a = expr(d + 1);
      if (peek.type != _T.colon) throw ExprError('expected ":"', peek.pos);
      next();
      final b = expr(d + 1);
      return _Cond(c, a, b);
    }
    return c;
  }

  Expr _or(int d) {
    var e = _and(d);
    while (_isOp('||')) {
      next();
      e = _Bin('||', e, _and(d));
    }
    return e;
  }

  Expr _and(int d) {
    var e = _cmp(d);
    while (_isOp('&&')) {
      next();
      e = _Bin('&&', e, _cmp(d));
    }
    return e;
  }

  Expr _cmp(int d) {
    final e = _sum(d);
    const cmps = {'<', '<=', '>', '>=', '==', '!='};
    if (peek.type == _T.op && cmps.contains(peek.text)) {
      final op = next().text;
      return _Bin(op, e, _sum(d));
    }
    return e;
  }

  Expr _sum(int d) {
    var e = _prod(d);
    while (_isOp('+') || _isOp('-')) {
      final op = next().text;
      e = _Bin(op, e, _prod(d));
    }
    return e;
  }

  Expr _prod(int d) {
    var e = _unary(d);
    while (_isOp('*') || _isOp('/') || _isOp('%')) {
      final op = next().text;
      e = _Bin(op, e, _unary(d));
    }
    return e;
  }

  Expr _unary(int d) {
    _depth(d);
    if (_isOp('-')) {
      next();
      return _Neg(_unary(d + 1));
    }
    return _atom(d);
  }

  Expr _atom(int d) {
    final t = next();
    switch (t.type) {
      case _T.num:
        return _Num(double.parse(t.text));
      case _T.ident:
        if (peek.type == _T.lparen) {
          final arity = _Call.functions[t.text];
          if (arity == null) {
            throw ExprError('unknown function "${t.text}"', t.pos);
          }
          next();
          final args = <Expr>[expr(d + 1)];
          while (peek.type == _T.comma) {
            next();
            args.add(expr(d + 1));
          }
          if (peek.type != _T.rparen) throw ExprError('expected ")"', peek.pos);
          next();
          if (args.length < arity.$1 || args.length > arity.$2) {
            throw ExprError('wrong number of arguments to ${t.text}', t.pos);
          }
          return _Call(t.text, args);
        }
        if (known != null && !known!.contains(t.text)) {
          throw ExprError('unknown input "${t.text}"', t.pos);
        }
        return _Ident(t.text);
      case _T.lparen:
        final e = expr(d + 1);
        if (peek.type != _T.rparen) throw ExprError('expected ")"', peek.pos);
        next();
        return e;
      default:
        throw ExprError(
          t.type == _T.end ? 'unexpected end' : 'unexpected "${t.text}"',
          t.pos,
        );
    }
  }
}
