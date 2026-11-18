// OpenUI Lang lexer, statement splitter and Pratt expression parser.
//
// Ported from @openuidev/lang-core (MIT, Copyright (c) Thesys Inc.):
// parser/tokens.ts, parser/lexer.ts, parser/statements.ts and
// parser/expressions.ts. Lexing and parsing never throw.

import 'ast.dart';
import 'builtins.dart' show isBuiltin;

enum T {
  newline,
  lParen,
  rParen,
  lBrack,
  rBrack,
  lBrace,
  rBrace,
  comma,
  colon,
  equals,
  trueKw,
  falseKw,
  nullKw,
  eof,
  str,
  num,
  ident,
  type,
  stateVar,
  dot,
  plus,
  minus,
  star,
  slash,
  percent,
  eqEq,
  notEq,
  greater,
  less,
  greaterEq,
  lessEq,
  and,
  or,
  not,
  question,
  builtinCall,
}

class Token {
  const Token(this.t, [this.v, this.start]);
  final T t;

  /// String for str/ident/type/stateVar/builtinCall, double for num.
  final Object? v;

  /// Source offset, set on identifiers, newlines and EOF.
  final int? start;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isAlpha(int c) =>
    (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x5f;
bool _isAlnum(int c) => _isAlpha(c) || _isDigit(c);

/// Decodes the body of a double-quoted string with JSON escapes. Lenient:
/// raw newlines are kept, an unknown escape keeps its character, and a
/// partial `\u` escape at the end (streaming) is dropped.
String _unescapeDouble(String body) {
  if (!body.contains(r'\')) return body;
  final b = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c != r'\') {
      b.write(c);
      continue;
    }
    i++;
    if (i >= body.length) break;
    final e = body[i];
    switch (e) {
      case 'n':
        b.write('\n');
      case 't':
        b.write('\t');
      case 'r':
        b.write('\r');
      case 'b':
        b.write('\b');
      case 'f':
        b.write('\f');
      case 'u':
        final hex = i + 4 < body.length ? body.substring(i + 1, i + 5) : '';
        final code = RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)
            ? int.parse(hex, radix: 16)
            : null;
        if (code != null) {
          b.writeCharCode(code);
          i += 4;
          break;
        }
        // A partial or malformed escape: dropped.
        i = body.length;
      default:
        b.write(e);
    }
  }
  return b.toString();
}

/// Tokenizes OpenUI Lang source. Never fails: unknown characters are skipped.
List<Token> tokenize(String src) {
  final tokens = <Token>[];
  var i = 0;
  final n = src.length;
  int at(int k) => k < n ? src.codeUnitAt(k) : -1;

  while (i < n) {
    while (i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r')) {
      i++;
    }
    if (i >= n) break;
    final c = src[i];
    final cc = src.codeUnitAt(i);

    void push(T t, [int len = 1]) {
      tokens.add(Token(t));
      i += len;
    }

    switch (c) {
      case '\n':
        tokens.add(Token(T.newline, null, i));
        i++;
        continue;
      case '(':
        push(T.lParen);
        continue;
      case ')':
        push(T.rParen);
        continue;
      case '[':
        push(T.lBrack);
        continue;
      case ']':
        push(T.rBrack);
        continue;
      case '{':
        push(T.lBrace);
        continue;
      case '}':
        push(T.rBrace);
        continue;
      case ',':
        push(T.comma);
        continue;
      case ':':
        push(T.colon);
        continue;
      case '=':
        at(i + 1) == 0x3d ? push(T.eqEq, 2) : push(T.equals);
        continue;
      case '!':
        at(i + 1) == 0x3d ? push(T.notEq, 2) : push(T.not);
        continue;
      case '>':
        at(i + 1) == 0x3d ? push(T.greaterEq, 2) : push(T.greater);
        continue;
      case '<':
        at(i + 1) == 0x3d ? push(T.lessEq, 2) : push(T.less);
        continue;
      case '&':
        at(i + 1) == 0x26 ? push(T.and, 2) : push(T.and);
        continue;
      case '|':
        at(i + 1) == 0x7c ? push(T.or, 2) : push(T.or);
        continue;
      case '.':
        push(T.dot);
        continue;
      case '?':
        push(T.question);
        continue;
      case '+':
        push(T.plus);
        continue;
      case '*':
        push(T.star);
        continue;
      case '%':
        push(T.percent);
        continue;
    }

    // Line comments: // or # to the end of the line.
    if (c == '#' || (c == '/' && at(i + 1) == 0x2f)) {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/') {
      push(T.slash);
      continue;
    }

    if (c == '"') {
      final start = i;
      i++;
      var closed = false;
      while (i < n) {
        if (src[i] == r'\') {
          i += 2;
        } else if (src[i] == '"') {
          i++;
          closed = true;
          break;
        } else {
          i++;
        }
      }
      if (i > n) i = n;
      final raw = src.substring(start + 1, closed ? i - 1 : i);
      tokens.add(Token(T.str, _unescapeDouble(raw)));
      continue;
    }

    if (c == "'") {
      i++;
      final b = StringBuffer();
      while (i < n) {
        if (src[i] == r'\') {
          i++;
          if (i < n) {
            final e = src[i];
            b.write(switch (e) {
              "'" => "'",
              r'\' => r'\',
              'n' => '\n',
              't' => '\t',
              _ => e,
            });
            i++;
          }
        } else if (src[i] == "'") {
          i++;
          break;
        } else {
          b.write(src[i]);
          i++;
        }
      }
      tokens.add(Token(T.str, b.toString()));
      continue;
    }

    if (c == '-') {
      final prev = tokens.isEmpty ? null : tokens.last.t;
      final afterValue = prev != null &&
          const {
            T.num,
            T.str,
            T.ident,
            T.type,
            T.rParen,
            T.rBrack,
            T.trueKw,
            T.falseKw,
            T.nullKw,
            T.stateVar,
            T.builtinCall,
          }.contains(prev);
      if (afterValue || !_isDigit(at(i + 1))) {
        push(T.minus);
        continue;
      }
    }

    if (_isDigit(cc) || (c == '-' && _isDigit(at(i + 1)))) {
      final start = i;
      if (src[i] == '-') i++;
      while (i < n && _isDigit(src.codeUnitAt(i))) {
        i++;
      }
      if (i < n && src[i] == '.' && _isDigit(at(i + 1))) {
        i++;
        while (i < n && _isDigit(src.codeUnitAt(i))) {
          i++;
        }
      }
      if (i < n && (src[i] == 'e' || src[i] == 'E')) {
        i++;
        if (i < n && (src[i] == '+' || src[i] == '-')) i++;
        while (i < n && _isDigit(src.codeUnitAt(i))) {
          i++;
        }
      }
      // A dangling exponent ("1e") is implementation-defined: read the digits.
      final text = src.substring(start, i);
      final v = double.tryParse(text) ??
          double.tryParse(text.replaceAll(RegExp(r'[eE][+-]?$'), '')) ??
          0.0;
      tokens.add(Token(T.num, v));
      continue;
    }

    if (c == r'$' && _isAlpha(at(i + 1))) {
      final start = i;
      i++;
      while (i < n && _isAlnum(src.codeUnitAt(i))) {
        i++;
      }
      tokens.add(Token(T.stateVar, src.substring(start, i), start));
      continue;
    }

    if (_isAlpha(cc)) {
      final start = i;
      while (i < n && _isAlnum(src.codeUnitAt(i))) {
        i++;
      }
      final word = src.substring(start, i);
      if (word == 'true') {
        tokens.add(const Token(T.trueKw));
      } else if (word == 'false') {
        tokens.add(const Token(T.falseKw));
      } else if (word == 'null') {
        tokens.add(const Token(T.nullKw));
      } else {
        final upper = cc >= 0x41 && cc <= 0x5a;
        tokens.add(Token(upper ? T.type : T.ident, word, start));
      }
      continue;
    }

    if (c == '@' && _isAlpha(at(i + 1))) {
      i++;
      final start = i;
      while (i < n && _isAlnum(src.codeUnitAt(i))) {
        i++;
      }
      tokens.add(Token(T.builtinCall, src.substring(start, i)));
      continue;
    }

    i++; // any other character (emoji, ';')
  }
  tokens.add(Token(T.eof, null, n));
  return tokens;
}

// ─── Statements ───────────────────────────────────────────────────────────

class RawStmt {
  RawStmt(this.id, this.idType, this.tokens);
  final String id;
  final T idType;
  final List<Token> tokens;
}

/// Closes an unterminated string and unclosed brackets so partial input
/// parses (language.md §4 rule 2).
({String text, bool wasIncomplete}) autoClose(String input) {
  final stack = <String>[];
  String? inStr;
  var esc = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (esc) {
      esc = false;
      continue;
    }
    if (c == r'\' && inStr != null) {
      esc = true;
      continue;
    }
    if (inStr != null) {
      if (c == inStr) inStr = null;
      continue;
    }
    if (c == '"' || c == "'") {
      inStr = c;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      stack.add(c);
    } else if (stack.isNotEmpty &&
        ((c == ')' && stack.last == '(') ||
            (c == ']' && stack.last == '[') ||
            (c == '}' && stack.last == '{'))) {
      stack.removeLast();
    }
  }
  final incomplete = inStr != null || stack.isNotEmpty;
  if (!incomplete) return (text: input, wasIncomplete: false);
  final b = StringBuffer(input);
  if (inStr != null) {
    if (esc) b.write(r'\');
    b.write(inStr);
  }
  for (var j = stack.length - 1; j >= 0; j--) {
    b.write(switch (stack[j]) { '(' => ')', '[' => ']', _ => '}' });
  }
  return (text: b.toString(), wasIncomplete: true);
}

/// Splits tokens into `name = expression` statements; other lines are skipped.
List<RawStmt> split(List<Token> tokens) {
  final out = <RawStmt>[];
  var pos = 0;
  final len = tokens.length;
  void skipLine() {
    while (pos < len &&
        tokens[pos].t != T.newline &&
        tokens[pos].t != T.eof) {
      pos++;
    }
  }

  while (pos < len) {
    while (pos < len && tokens[pos].t == T.newline) {
      pos++;
    }
    if (pos >= len || tokens[pos].t == T.eof) break;
    final tok = tokens[pos];
    if (tok.t != T.ident && tok.t != T.type && tok.t != T.stateVar) {
      skipLine();
      continue;
    }
    pos++;
    if (pos >= len || tokens[pos].t != T.equals) {
      skipLine();
      continue;
    }
    pos++;
    final expr = <Token>[];
    var depth = 0;
    var ternary = 0;
    while (pos < len && tokens[pos].t != T.eof) {
      final tt = tokens[pos].t;
      if (tt == T.newline && depth <= 0 && ternary <= 0) {
        var peek = pos + 1;
        while (peek < len && tokens[peek].t == T.newline) {
          peek++;
        }
        final next = peek < len ? tokens[peek].t : T.eof;
        if (next == T.question || (next == T.colon && ternary > 0)) {
          pos++;
          continue;
        }
        break;
      }
      if (tt == T.newline) {
        pos++;
        continue;
      }
      if (tt == T.lParen || tt == T.lBrack || tt == T.lBrace) {
        depth++;
      } else if ((tt == T.rParen || tt == T.rBrack || tt == T.rBrace) &&
          depth > 0) {
        depth--;
      } else if (tt == T.question && depth == 0) {
        ternary++;
      } else if (tt == T.colon && depth == 0 && ternary > 0) {
        ternary--;
      }
      expr.add(tokens[pos++]);
    }
    if (expr.isNotEmpty) out.add(RawStmt(tok.v! as String, tok.t, expr));
  }
  return out;
}

// ─── Expressions ──────────────────────────────────────────────────────────

const _precTernary = 1,
    _precOr = 2,
    _precAnd = 3,
    _precEq = 4,
    _precCmp = 5,
    _precAdd = 6,
    _precMul = 7,
    _precUnary = 8,
    _precMember = 9;

/// Max nesting while parsing one expression; deeper input parses as null.
const int maxExpressionDepth = 64;

Node parseExpression(List<Token> tokens) => _ExprParser(tokens).parse();

class _ExprParser {
  _ExprParser(this.tokens);
  final List<Token> tokens;
  int pos = 0;
  int depth = 0;

  static const _eofTok = Token(T.eof);
  Token get cur => pos < tokens.length ? tokens[pos] : _eofTok;
  Token adv() {
    final t = cur;
    pos++;
    return t;
  }

  void eat(T t) {
    if (cur.t == t) pos++;
  }

  Node parse() => expr(0);

  int infixPrec(Token t) => switch (t.t) {
    T.question => _precTernary,
    T.or => _precOr,
    T.and => _precAnd,
    T.eqEq || T.notEq => _precEq,
    T.greater || T.less || T.greaterEq || T.lessEq => _precCmp,
    T.plus || T.minus => _precAdd,
    T.star || T.slash || T.percent => _precMul,
    T.dot || T.lBrack => _precMember,
    _ => 0,
  };

  Node expr(int minPrec) {
    if (++depth > maxExpressionDepth) {
      // Too deep: consume the rest of this run so we terminate.
      depth--;
      while (cur.t != T.eof) {
        adv();
      }
      return const NullLit();
    }
    var left = prefix();
    while (infixPrec(cur) > minPrec) {
      left = infix(left);
    }
    depth--;
    return left;
  }

  Node prefix() {
    final tok = cur;
    switch (tok.t) {
      case T.str:
        adv();
        return Str(tok.v! as String);
      case T.num:
        adv();
        return Num(tok.v! as double);
      case T.trueKw:
        adv();
        return const Bool(true);
      case T.falseKw:
        adv();
        return const Bool(false);
      case T.nullKw:
        adv();
        return const NullLit();
      case T.lBrack:
        return arr();
      case T.lBrace:
        return obj();
      case T.stateVar:
        final name = tok.v! as String;
        adv();
        if (cur.t == T.equals) {
          adv();
          return Assign(name, expr(0));
        }
        return StateRef(name);
      case T.type:
        final name = tok.v! as String;
        final next = pos + 1 < tokens.length ? tokens[pos + 1].t : T.eof;
        if (next == T.lParen && (!isBuiltin(name) || name == 'Action')) {
          return comp();
        }
        adv();
        return Ref(name);
      case T.builtinCall:
        final next = pos + 1 < tokens.length ? tokens[pos + 1].t : T.eof;
        if (next == T.lParen) {
          final call = comp();
          if (!isBuiltin(call.name)) call.fn = true;
          return call;
        }
        adv();
        return Ref(tok.v! as String);
      case T.ident:
        adv();
        return Ref(tok.v! as String);
      case T.not:
        adv();
        return UnaryOp('!', expr(_precUnary));
      case T.minus:
        adv();
        return UnaryOp('-', expr(_precUnary));
      case T.lParen:
        adv();
        final inner = expr(0);
        eat(T.rParen);
        return inner;
      default:
        adv();
        return const NullLit();
    }
  }

  static const _binOps = {
    T.plus: ('+', _precAdd),
    T.minus: ('-', _precAdd),
    T.star: ('*', _precMul),
    T.slash: ('/', _precMul),
    T.percent: ('%', _precMul),
    T.eqEq: ('==', _precEq),
    T.notEq: ('!=', _precEq),
    T.greater: ('>', _precCmp),
    T.less: ('<', _precCmp),
    T.greaterEq: ('>=', _precCmp),
    T.lessEq: ('<=', _precCmp),
    T.and: ('&&', _precAnd),
    T.or: ('||', _precOr),
  };

  String fieldName(Token t) {
    adv();
    return switch (t.t) {
      T.ident || T.type || T.str => t.v! as String,
      T.num => jsNumberToString(t.v! as double),
      T.stateVar => (t.v! as String).substring(1),
      _ => '?',
    };
  }

  Node infix(Node left) {
    final tok = cur;
    final bin = _binOps[tok.t];
    if (bin != null) {
      adv();
      return BinOp(bin.$1, left, expr(bin.$2));
    }
    if (tok.t == T.question) {
      adv();
      final then = expr(0);
      eat(T.colon);
      return Ternary(left, then, expr(0));
    }
    if (tok.t == T.dot) {
      adv();
      return Member(left, fieldName(cur));
    }
    if (tok.t == T.lBrack) {
      adv();
      final index = expr(0);
      eat(T.rBrack);
      return Index(left, index);
    }
    return left;
  }

  Comp comp() {
    final name = cur.v! as String;
    adv();
    eat(T.lParen);
    final args = <Node>[];
    while (cur.t != T.rParen && cur.t != T.eof) {
      args.add(expr(0));
      if (cur.t == T.comma) adv();
    }
    eat(T.rParen);
    return Comp(name, args);
  }

  Node arr() {
    adv();
    final els = <Node>[];
    while (cur.t != T.rBrack && cur.t != T.eof) {
      els.add(expr(0));
      if (cur.t == T.comma) adv();
    }
    eat(T.rBrack);
    return Arr(els);
  }

  Node obj() {
    adv();
    final entries = <(String, Node)>[];
    while (cur.t != T.rBrace && cur.t != T.eof) {
      final key = fieldName(cur);
      eat(T.colon);
      entries.add((key, expr(0)));
      if (cur.t == T.comma) adv();
    }
    eat(T.rBrace);
    return Obj(entries);
  }
}

/// ECMAScript Number::toString for the values OpenUI produces.
String jsNumberToString(num v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  if (v == v.truncateToDouble() && v.abs() < 1e21) {
    return v.toInt().toString();
  }
  var s = v.toString();
  // Dart writes 1e-7 as "1e-7" like JS; 1.5e+21 as "1.5e+21" like JS.
  if (s.contains('e') && !s.contains('e-') && !s.contains('e+')) {
    s = s.replaceFirst('e', 'e+');
  }
  return s;
}
