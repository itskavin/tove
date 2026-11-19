import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/markdown/plain_math.dart';

void main() {
  test('display and inline maths become readable text', () {
    expect(
      plainMath(r'Split: \[ 2x^2 - 6x - x + 3 = 0 \]'),
      'Split: 2x² − 6x − x + 3 = 0',
    );
    expect(plainMath(r'\[ 2x-1=0 \implies x=\frac12 \]'), '2x−1=0 ⇒ x=1/2');
    expect(
      plainMath(r'\( x = \frac{-b \pm \sqrt{b^2-4ac}}{2a} \)'),
      'x = (−b ± √(b²−4ac))/(2a)',
    );
    expect(plainMath(r'$$\text{Area} = \pi r^2$$'), 'Area = π r²');
    expect(plainMath(r'$$a_{n+1} = a_n \times 2$$'), 'a_(n+1) = a_n × 2');
  });

  test('prices, code and plain text are left alone', () {
    expect(plainMath(r'It costs $5 or $10.'), r'It costs $5 or $10.');
    expect(plainMath('Use `\\[x\\]` in LaTeX'), 'Use `\\[x\\]` in LaTeX');
    expect(plainMath('```\n\\[x\\]\n```'), '```\n\\[x\\]\n```');
    expect(plainMath('No maths here (really).'), 'No maths here (really).');
  });
}
