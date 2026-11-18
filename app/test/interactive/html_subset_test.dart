import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/interactive/html_subset.dart';
import 'package:tove_chat/src/ui/markdown/md_render.dart';
import 'package:markdown/markdown.dart' as md;

/// A compact tree dump: elements as tag(children), text verbatim.
String dump(List<md.Node> nodes) => nodes
    .map(
      (n) => n is md.Element
          ? '${n.tag}(${dump(n.children ?? const [])})'
          : n.textContent,
    )
    .join();

String parse(String src) => dump(parseMarkdownBlock(src));

void main() {
  test('allowed inline tags become elements; attributes are ignored', () {
    expect(parse('a <small class="x">fine</small> b'), 'p(a small(fine) b)');
    expect(
      parse('Press <kbd>Ctrl</kbd>+<kbd>C</kbd>'),
      'p(Press kbd(Ctrl)+kbd(C))',
    );
    expect(
      parse('<mark>hi</mark> <u>u</u> H<sub>2</sub>O x<sup>2</sup>'),
      'p(mark(hi) u(u) Hsub(2)O xsup(2))',
    );
    expect(parse('one<br>two<br/>three'), 'p(onebr()twobr()three)');
  });

  test('markdown inside an allowed tag keeps working', () {
    expect(parse('<small>see **this**</small>'), 'p(small(see strong(this)))');
  });

  test('every other tag stays visible as literal text', () {
    expect(
      parse('<script>alert(1)</script>'),
      contains('<script>alert(1)</script>'),
    );
    expect(
      parse('x <img src=x onerror=alert(1)> y'),
      'p(x <img src=x onerror=alert(1)> y)',
    );
    expect(parse('a <b>bold</b> c'), 'p(a <b>bold</b> c)');
    expect(
      parse('<iframe src="https://e.com"></iframe>'),
      contains('<iframe src="https://e.com"></iframe>'),
    );
    expect(parse('<div>block</div>'), contains('<div>block</div>'));
  });

  test('unclosed or stray allowed tags stay literal', () {
    expect(parse('a <small>never closed'), 'p(a <small>never closed)');
    expect(parse('a </small> b'), 'p(a </small> b)');
    expect(parse('<small><kbd>x</small>'), 'p(small(<kbd>x))');
  });

  test('tags inside code spans are code', () {
    expect(parse('`<small>x</small>`'), 'p(code(<small>x</small>))');
  });

  test('<details> blocks parse with their summary and body', () {
    final d = parseDetailsHtml(
      '<details open>\n<summary>More <b>info</b></summary>\n\nBody **bold**.\n\nSecond.\n</details>',
    )!;
    expect(d.summary, 'More info');
    expect(d.open, isTrue);
    expect(d.closed, isTrue);
    expect(d.body, 'Body **bold**.\n\nSecond.');
    final nodes = parseMarkdownBlock(
      '<details>\n<summary>Why</summary>\n\n- a\n- b\n</details>',
    );
    expect(dump(nodes), 'x-details(ul(li(a)li(b)))');
    expect((nodes.single as md.Element).attributes['summary'], 'Why');
    final partial = parseDetailsHtml('<details>\n<summary>Wh');
    expect(partial!.closed, isFalse);
    expect(partial.body, isEmpty);
    expect(parseDetailsHtml('Not details'), isNull);
  });

  test('repairInlineHtml closes open tags and hides half-typed ones', () {
    expect(repairInlineHtml('a <small>b'), 'a <small>b</small>');
    expect(repairInlineHtml('a <sma'), 'a ');
    expect(repairInlineHtml('a <small>b</sm'), 'a <small>b</small>');
    expect(repairInlineHtml('a <'), 'a ');
    expect(repairInlineHtml('x <script'), 'x <script');
    expect(repairInlineHtml('`<small>` ok'), '`<small>` ok');
  });
}
