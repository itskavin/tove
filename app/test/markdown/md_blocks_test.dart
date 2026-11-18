import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/markdown/md_blocks.dart';

void main() {
  group('splitBlocks', () {
    test('splits at blank lines', () {
      expect(splitBlocks('a\nb\n\nc\n\n\n# d'), ['a\nb', 'c', '# d']);
    });

    test('keeps blank lines inside code fences', () {
      const text = 'intro\n\n```py\nx = 1\n\ny = 2\n```\n\nafter';
      expect(splitBlocks(text), [
        'intro',
        '```py\nx = 1\n\ny = 2\n```',
        'after',
      ]);
    });

    test('an unterminated fence runs to the end', () {
      expect(splitBlocks('```\na\n\nb'), ['```\na\n\nb']);
    });

    test('tilde fences and longer closers', () {
      expect(splitBlocks('~~~~\na\n\n~~~~~\n\nb'), ['~~~~\na\n\n~~~~~', 'b']);
    });

    test('an indented line after a blank continues a list', () {
      const text = '- a\n\n  - nested\n\n- b\n\npara';
      expect(splitBlocks(text), ['- a\n\n  - nested', '- b', 'para']);
    });

    test('an indented line after a paragraph starts a new block', () {
      expect(splitBlocks('para\n\n    code'), ['para', '    code']);
    });

    test('scanning from a block start gives the same tail', () {
      const text = 'one\n\ntwo\n\nthree';
      final all = splitBlockRanges(text);
      final tail = splitBlockRanges(text, from: all[1].start);
      expect(tail, all.sublist(1));
    });

    test('heading helpers', () {
      expect(startsWithHeading('## T\nbody'), isTrue);
      expect(endsWithHeading('body\n### T'), isTrue);
      expect(startsWithHeading('#hashtag'), isFalse);
    });
  });

  group('repairPartial', () {
    test('closes an open code fence', () {
      expect(repairPartial('```dart\nvoid main'), '```dart\nvoid main\n```');
    });

    test('hides a half-typed closing fence', () {
      expect(repairPartial('```\ncode\n``'), '```\ncode\n```');
    });

    test('waits for the info string to finish', () {
      expect(repairPartial('```pyt'), '```\n```');
    });

    test('leaves a complete block alone', () {
      const s = 'Some **bold** and `code` and [a](https://x.dev).';
      expect(repairPartial(s), s);
    });

    test('closes bold, italic, strikethrough and code', () {
      expect(repairPartial('a **bol'), 'a **bol**');
      expect(repairPartial('a *it'), 'a *it*');
      expect(repairPartial('a _it'), 'a _it_');
      expect(repairPartial('a ~~gone'), 'a ~~gone~~');
      expect(repairPartial('use `foo'), 'use `foo`');
      expect(repairPartial('**bold *both'), '**bold *both***');
    });

    test('holds back an opener with nothing after it', () {
      expect(repairPartial('foo **').trimRight(), 'foo');
      expect(repairPartial('**bold*'), '**bold**');
      expect(repairPartial('tick `').trimRight(), 'tick');
    });

    test('ignores underscores inside words and URLs', () {
      expect(repairPartial('snake_case_name'), 'snake_case_name');
      expect(
        repairPartial('see https://x.dev/_next/a_b'),
        'see https://x.dev/_next/a_b',
      );
    });

    test('an unfinished link shows its text only', () {
      expect(repairPartial('see [the docs](https://exa'), 'see the docs');
      expect(repairPartial('see [the do'), 'see the do');
      expect(repairPartial('see [the docs]'), 'see the docs');
    });

    test('an unfinished image shows nothing yet', () {
      expect(repairPartial('pic ![alt](http://x').trimRight(), 'pic');
    });

    test('drops a trailing marker-only line', () {
      expect(repairPartial('para\n#'), 'para');
      expect(repairPartial('- a\n-'), '- a');
      expect(repairPartial('1. a\n2.'), '1. a');
      expect(repairPartial('1. a\n2'), '1. a');
      expect(repairPartial('> q\n>'), '> q');
      expect(repairPartial('#'), '');
      expect(repairPartial('- [ ]'), '');
    });

    test('holds a table back until its separator covers every column', () {
      expect(repairPartial('Intro\n| a | b |'), 'Intro');
      expect(repairPartial('| a | b | c |\n|---|---|'), '');
      expect(
        repairPartial('| a | b |\n|---|---|\n| 1 | 2'),
        '| a | b |\n|---|---|\n| 1 | 2',
      );
    });
  });

  group('normalizeBulletGlyphs (round-2 device QA)', () {
    test('glyph bullets on single lines become a list', () {
      expect(
        normalizeBulletGlyphs('• Pathfinder: up\n• NAS-01: up\n  ◦ nested'),
        '- Pathfinder: up\n- NAS-01: up\n  - nested',
      );
    });
    test('code fences and mid-line dots are left alone', () {
      const src = 'A • B\n```\n• in code\n```\n• after';
      expect(normalizeBulletGlyphs(src), 'A • B\n```\n• in code\n```\n- after');
    });
  });
}
