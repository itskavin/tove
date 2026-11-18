import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/interactive/expr.dart';

void main() {
  double? ev(String src, [Map<String, double> env = const {}]) =>
      Expr.parse(src, known: env.keys.toSet()).eval(env);

  test('arithmetic precedence and associativity', () {
    expect(ev('1 + 2 * 3'), 7);
    expect(ev('(1 + 2) * 3'), 9);
    expect(ev('10 - 4 - 3'), 3);
    expect(ev('2 * 3 % 4'), 2);
    expect(ev('-2 * -3'), 6);
    expect(ev('--4'), 4);
    expect(ev('.5 + 1.25'), 1.75);
  });

  test('the measured calculator values', () {
    for (final (m, cost) in [(60.0, 3.0), (190.0, 9.5), (470.0, 23.5)]) {
      expect(ev('minutes * 0.05', {'minutes': m}), closeTo(cost, 1e-9));
    }
  });

  test('comparisons, logic and the ternary', () {
    expect(ev('1 < 2'), 1);
    expect(ev('2 <= 1'), 0);
    expect(ev('3 == 3 && 2 != 2'), 0);
    expect(ev('0 || 5'), 1);
    expect(ev('x > 10 ? x * 2 : x / 2', {'x': 20}), 40);
    expect(ev('x > 10 ? x * 2 : x / 2', {'x': 4}), 2);
    expect(ev('a ? b ? 1 : 2 : 3', {'a': 1, 'b': 0}), 2);
  });

  test('functions', () {
    expect(ev('min(3, 1, 2)'), 1);
    expect(ev('max(3, 1, 2)'), 3);
    expect(ev('round(2.345, 2)'), 2.35);
    expect(ev('round(2.5)'), 3);
    expect(ev('floor(2.9) + ceil(2.1)'), 5);
    expect(ev('abs(-4)'), 4);
    expect(ev('clamp(15, 0, 10)'), 10);
    expect(ev('clamp(1, 5, 0)'), isNull);
  });

  test('division or modulo by zero gives null, which propagates', () {
    expect(ev('1 / 0'), isNull);
    expect(ev('1 % 0'), isNull);
    expect(ev('(1 / 0) + 2'), isNull);
    expect(ev('max(1, 1 / x)', {'x': 0}), isNull);
  });

  test('identifiers with hyphens prefer known ids, else minus', () {
    expect(ev('use-case * 2', {'use-case': 3}), 6);
    expect(ev('a-b', {'a': 5, 'b': 2}), 3);
    expect(ev('a - b', {'a': 5, 'b': 2}), 3);
  });

  test('identifiers are collected', () {
    expect(Expr.parse('a + max(b, 2) * c').identifiers, {'a', 'b', 'c'});
  });

  test('rejects anything outside the language', () {
    for (final bad in [
      '',
      '1 +',
      '(1',
      'foo(1)',
      'alert(1)',
      'x = 1',
      '"text"',
      "'a'",
      '1; 2',
      'a.b',
      '[1]',
      'round()',
      'clamp(1, 2)',
      'min(${List.filled(17, '1').join(',')})',
      'x ? 1',
      '1 ** 2',
    ]) {
      expect(() => Expr.parse(bad), throwsA(isA<ExprError>()), reason: bad);
    }
    expect(() => Expr.parse('y + 1', known: {'x'}), throwsA(isA<ExprError>()));
  });

  test('limits: 200 characters and nesting depth', () {
    expect(() => Expr.parse('1+' * 100 + '1'), throwsA(isA<ExprError>()));
    expect(Expr.parse('1+' * 99 + '1').eval(const {}), 100);
    expect(
      () => Expr.parse('${'(' * 40}1${')' * 40}'),
      throwsA(isA<ExprError>()),
    );
    expect(() => Expr.parse('${'-' * 40}1'), throwsA(isA<ExprError>()));
  });

  test('missing inputs evaluate to null', () {
    expect(Expr.parse('x + 1').eval(const {}), isNull);
  });
}
