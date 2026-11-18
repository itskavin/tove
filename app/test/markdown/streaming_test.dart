import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/markdown/md_render.dart';
import 'package:tove_chat/src/ui/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

/// A long reply mixing every block type; about [words] words.
String longReply(int words) {
  final b = StringBuffer();
  var n = 0;
  var i = 0;
  void para(String s) {
    b.write('$s\n\n');
    n += s.split(RegExp(r'\s+')).length;
  }

  while (n < words) {
    switch (i % 7) {
      case 0:
        para('## Section $i');
      case 1:
        para(
          'Paragraph $i has **bold words**, *a slanted phrase*, `inline_code()` '
          'and a [link](https://example.dev/p$i). It keeps going for a while so '
          'the block is a realistic length for a reply, with several clauses, '
          'commas, and ordinary words that a model would write here.',
        );
      case 2:
        para(
          '- first point about item $i\n- second point\n  - nested detail\n- third',
        );
      case 3:
        para(
          '```dart\nvoid f$i() {\n  print("hello $i");\n\n  return;\n}\n```',
        );
      case 4:
        para(
          '| Key | Value | Note |\n|---|---|---|\n| a$i | 1 | fine |\n| b$i | 2 | also fine |',
        );
      case 5:
        para('> A quoted remark number $i that spans a line or two of text.');
      case 6:
        para(
          '1. step one for $i\n2. step two with more words\n3. step three '
          'and the end of the list',
        );
    }
    i++;
  }
  return b.toString().trimRight();
}

/// Splits [text] into chunks of about [words] words, like network deltas.
List<String> chunks(String text, int words) {
  final out = <String>[];
  final re = RegExp(r'\S+\s*');
  final ms = re.allMatches(text).toList();
  for (var i = 0; i < ms.length; i += words) {
    final end = (i + words < ms.length) ? ms[i + words].start : text.length;
    out.add(text.substring(ms[i].start, end));
  }
  if (ms.isNotEmpty && ms.first.start > 0) {
    out[0] = text.substring(0, ms.first.start) + out[0];
  }
  return out;
}

void main() {
  tearDown(() => MarkdownDebug.onBlockBuild = null);

  testWidgets('3,000 words at 30 updates/s: completed blocks never rebuild', (
    tester,
  ) async {
    setSurface(tester, 412);
    final reply = longReply(3000);
    final parts = chunks(reply, 5);
    expect(reply.split(RegExp(r'\s+')).length, greaterThanOrEqualTo(3000));

    final source = ValueNotifier('');
    var streaming = true;
    late StateSetter setOuter;
    // Index -> builds after the block was first built settled (not live).
    final settledAt = <int, int>{};
    final buildsAfterSettled = <int, int>{};
    final builds = <int, int>{};
    MarkdownDebug.onBlockBuild = (i, live) {
      builds[i] = (builds[i] ?? 0) + 1;
      if (settledAt.containsKey(i)) {
        buildsAfterSettled[i] = (buildsAfterSettled[i] ?? 0) + 1;
      } else if (!live) {
        settledAt[i] = builds[i]!;
      }
    };

    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, set) {
            setOuter = set;
            return StreamingMarkdown.listenable(
              source: source,
              isStreaming: streaming,
              smoothReveal: false,
            );
          },
        ),
      ),
    );

    final parsesBefore = MarkdownDebug.parseCount;
    final sw = Stopwatch()..start();
    var acc = '';
    final lap = <int>[];
    for (final p in parts) {
      final t0 = sw.elapsedMicroseconds;
      acc += p;
      source.value = acc;
      await tester.pump(const Duration(milliseconds: 33));
      lap.add(sw.elapsedMicroseconds - t0);
    }
    sw.stop();
    String avg(Iterable<int> xs) =>
        (xs.fold<int>(0, (a, b) => a + b) / xs.length / 1000).toStringAsFixed(
          2,
        );
    debugPrint(
      'first 100 updates: ${avg(lap.take(100))} ms, '
      'last 100: ${avg(lap.skip(lap.length - 100))} ms',
    );
    setOuter(() => streaming = false);
    await tester.pumpAndSettle();
    final parses = MarkdownDebug.parseCount - parsesBefore;

    final blocks = builds.keys.length;
    debugPrint(
      'stream: ${parts.length} updates, $blocks blocks, $parses parses, '
      '${builds.values.fold<int>(0, (a, b) => a + b)} block builds, '
      '${(sw.elapsedMicroseconds / parts.length / 1000).toStringAsFixed(2)} '
      'ms per update (test host, debug mode)',
    );
    expect(blocks, greaterThan(100));
    // Once a block has settled, nothing rebuilds it.
    expect(buildsAfterSettled, isEmpty);
    expect(settledAt.length, blocks);
    // Only the trailing block is re-parsed: about one parse per update plus
    // one per block when it completes.
    expect(parses, lessThanOrEqualTo(parts.length + 2 * blocks + 4));
    // The result matches rendering the whole text at once.
    final streamed = visibleText(tester);
    await tester.pumpWidget(host(HermesMarkdown(text: reply)));
    expect(streamed, visibleText(tester));
  });

  testWidgets('partial markdown never shows raw markers while streaming', (
    tester,
  ) async {
    setSurface(tester, 412);
    const reply =
        'Intro with **bold text** and *slanted text* and ~~struck~~ and '
        '`code span` and [a link](https://example.dev/x).\n\n'
        '## Heading here\n\n'
        '- item one\n- item two\n\n'
        '> quoted\n\n'
        '| Col A | Col B |\n|---|---|\n| one | two |\n\n'
        '```python\nprint(42)\n```\n\n'
        'Done.';
    final source = ValueNotifier('');
    await tester.pumpWidget(
      host(StreamingMarkdown.listenable(source: source, smoothReveal: false)),
    );
    for (var i = 1; i <= reply.length; i++) {
      source.value = reply.substring(0, i);
      await tester.pump(const Duration(milliseconds: 16));
      final text = visibleText(tester);
      for (final raw in ['**', '`', '[', '](', '~~', '#', '|', '>']) {
        expect(
          text.contains(raw),
          isFalse,
          reason: '"$raw" visible at $i: $text',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('an unterminated code fence renders as a code block', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const StreamingMarkdown(
          text: 'Look:\n\n```sh\necho hi\nls',
          smoothReveal: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.text('sh'), findsOneWidget);
    expect(find.textContaining('echo hi\nls'), findsOneWidget);
    expect(visibleText(tester), isNot(contains('```')));
  });

  testWidgets('a half table is held back, then appears whole', (tester) async {
    final source = ValueNotifier('Table:\n\n| A | B |');
    await tester.pumpWidget(
      host(StreamingMarkdown.listenable(source: source, smoothReveal: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MdTable), findsNothing);
    expect(visibleText(tester), isNot(contains('|')));
    source.value = 'Table:\n\n| A | B |\n|---|---|\n| 1';
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MdTable), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('new text fades in linearly over 240 ms', (tester) async {
    const muted = HermesTokens.darkTokens;
    Widget w(String s) => host(StreamingMarkdown(text: s, smoothReveal: false));
    await tester.pumpWidget(w('Hello'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(spanWithText(tester, 'Hello')!.style!.color!.a, closeTo(1, 0.001));

    await tester.pumpWidget(w('Hello world'));
    double alpha() => styleOf(tester, ' world')!.color!.a;
    expect(alpha(), closeTo(0, 0.001));
    await tester.pump(); // the first frame that shows it starts the clock
    expect(alpha(), closeTo(0, 0.001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(alpha(), closeTo(0.5, 0.02));
    await tester.pump(const Duration(milliseconds: 60));
    expect(alpha(), closeTo(0.75, 0.02));
    // Older text is untouched.
    expect(styleOf(tester, 'Hello')!.color!.a, closeTo(1, 0.001));
    await tester.pump(const Duration(milliseconds: 80));
    expect(styleOf(tester, 'Hello world')!.color, muted.text);
    // The ticker stops when nothing is fading.
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final mode in ['system', 'app setting']) {
    testWidgets('no fade with reduced motion ($mode)', (tester) async {
      Widget w(ValueListenable<String> s) => host(
        StreamingMarkdown.listenable(source: s),
        disableAnimations: mode == 'system',
        reduceSetting: mode == 'app setting',
      );
      // One host for the whole test: rebuilding MaterialApp would animate
      // the theme and count as a running animation.
      final source = ValueNotifier('Hello');
      await tester.pumpWidget(w(source));
      await tester.pump(const Duration(seconds: 1));
      source.value = 'Hello world, and more words';
      await tester.pump();
      // Visible at full opacity on the very first frame, with no smoothing.
      expect(
        styleOf(tester, 'Hello world, and more words')!.color!.a,
        closeTo(1, 0.001),
      );
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('history (not streaming) shows at once without animation', (
    tester,
  ) async {
    await tester.pumpWidget(host(const HermesMarkdown(text: 'Old **reply**.')));
    expect(styleOf(tester, 'reply')!.color!.a, closeTo(1, 0.001));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('rate smoothing: bursts reveal at 90 chars/s, flush on done', (
    tester,
  ) async {
    final reply = List.filled(30, 'word').join(' '); // 149 chars
    var streaming = true;
    var revealed = 0;
    late StateSetter set;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, s) {
            set = s;
            return StreamingMarkdown(
              text: reply,
              isStreaming: streaming,
              onRevealed: () => revealed++,
            );
          },
        ),
      ),
    );
    int shown() => visibleText(tester).length;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // About 0.5 s at 90 chars/s.
    expect(shown(), inInclusiveRange(35, 55));
    expect(revealed, 0);

    set(() => streaming = false);
    await tester.pump();
    // The rest arrives within 300 ms, and finishes fading 240 ms later.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shown(), reply.length);
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    expect(revealed, 1);
    await tester.pumpAndSettle();
    expect(revealed, 1);
  });

  testWidgets('rate smoothing catches up when far behind', (tester) async {
    final reply = List.filled(400, 'word').join(' '); // 1999 chars
    await tester.pumpWidget(host(StreamingMarkdown(text: reply)));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // ~1 s: far more than 90 characters, but not everything at once.
    final n = visibleText(tester).length;
    expect(n, greaterThan(1200));
    expect(n, lessThan(reply.length));
  });

  testWidgets('completed blocks keep their state while the reply grows', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final source = ValueNotifier('```\ncode\n```\n\nNext');
    await tester.pumpWidget(
      host(StreamingMarkdown.listenable(source: source, smoothReveal: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    source.value = '```\ncode\n```\n\nNext paragraph grows.\n\nAnd another.';
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a non-continuation starts over', (tester) async {
    final source = ValueNotifier('First answer.\n\nMore.');
    await tester.pumpWidget(
      host(StreamingMarkdown.listenable(source: source, smoothReveal: false)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    source.value = 'Second answer.';
    await tester.pump(const Duration(milliseconds: 300));
    expect(visibleText(tester), 'Second answer.');
  });

  testWidgets('streaming at 200 % text scale has no overflow', (tester) async {
    setSurface(tester, 360);
    final reply = longReply(400);
    final source = ValueNotifier('');
    await tester.pumpWidget(
      host(
        StreamingMarkdown.listenable(source: source, smoothReveal: false),
        textScale: 2,
      ),
    );
    var acc = '';
    for (final p in chunks(reply, 8)) {
      acc += p;
      source.value = acc;
      await tester.pump(const Duration(milliseconds: 33));
      expect(tester.takeException(), isNull);
    }
  });
}
