import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/markdown/md_blocks.dart';
import 'package:tove_chat/src/ui/markdown/md_images.dart';

import 'helpers.dart';

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

LinkImage _image({int? w, int? h}) =>
    LinkImage(bytes: _png, url: 'https://i.example/a.png', width: w, height: h);

/// Answers loads only when the test completes them.
class FakeLoader implements MarkdownImageLoader {
  final results = <String, LinkImageResult>{};
  final pending = <String, Completer<LinkImageResult>>{};
  final calls = <String>[];

  @override
  LinkImageResult? peek(String url) => results[url];

  @override
  Future<LinkImageResult> load(String url, {bool retry = false}) {
    calls.add(retry ? 'retry $url' : url);
    if (retry) results.remove(url);
    final hit = results[url];
    if (hit != null) return SynchronousFuture(hit);
    return (pending[url] ??= Completer()).future;
  }

  void complete(String url, LinkImage? image) {
    final r = LinkImageResult(image);
    results[url] = r;
    pending.remove(url)?.complete(r);
  }
}

/// Lets a completed load show: the test binding runs microtasks after the
/// frame, so the tile's setState needs a second frame.
Future<void> settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  group('repairPartial: linked images', () {
    test('a linked image is held back until its page link closes', () {
      for (final partial in [
        '[![',
        '[![a cat',
        '[![a cat](https://i.example/c',
        '[![a cat](https://i.example/c.png)',
        '[![a cat](https://i.example/c.png)]',
        '[![a cat](https://i.example/c.png)](',
        '[![a cat](https://i.example/c.png)](https://page.exa',
      ]) {
        expect(
          repairPartial('Intro\n$partial').trimRight(),
          'Intro',
          reason: partial,
        );
      }
    });

    test('a finished linked image is kept', () {
      const done =
          '[![a cat](https://i.example/c.png)](https://page.example/x)';
      expect(repairPartial('Intro\n$done'), 'Intro\n$done');
    });

    test('a finished image stays while the next one is typed', () {
      expect(
        repairPartial('![a](https://i.example/a.png)\n![b](https://i.ex'),
        '![a](https://i.example/a.png)',
      );
    });
  });

  group('rendering', () {
    const w = 412.0;
    const inner = w - 32; // host() has 16 dp gutters

    Future<FakeLoader> show(
      WidgetTester tester,
      String md, {
      FakeLoader? loader,
      MarkdownLinkTap? onLinkTap,
      double textScale = 1,
      bool scope = true,
    }) async {
      setSurface(tester, w);
      final l = loader ?? FakeLoader();
      final body = HermesMarkdown(text: md, onLinkTap: onLinkTap ?? (_) {});
      await tester.pumpWidget(
        host(
          scope ? MarkdownImageScope(loader: l, child: body) : body,
          textScale: textScale,
        ),
      );
      await tester.pump();
      return l;
    }

    testWidgets('without a loader images stay pills', (tester) async {
      await show(tester, '![a cat](https://i.example/c.png)', scope: false);
      expect(find.text('[image: a cat]'), findsOneWidget);
      expect(find.byType(MdImageTile), findsNothing);
    });

    testWidgets('an image inside a sentence stays a pill', (tester) async {
      final l = await show(
        tester,
        'Here is ![a cat](https://i.example/c.png) in text.',
      );
      expect(find.text('[image: a cat]'), findsOneWidget);
      expect(find.byType(MdImageTile), findsNothing);
      expect(l.calls, isEmpty);
    });

    testWidgets('non-web image URLs are never loaded', (tester) async {
      final l = await show(tester, '![x](file:///etc/passwd)');
      expect(find.byType(MdImageTile), findsNothing);
      expect(l.calls, isEmpty);
    });

    testWidgets('a single image keeps its frame height from loading to '
        'loaded to failed', (tester) async {
      const url = 'https://i.example/c.png';
      const md = 'Before.\n\n![A grey cat](https://i.example/c.png)\n\nAfter.';
      final l = await show(tester, md);
      expect(l.calls, [url]);
      final frameH = MdImageGallery.singleHeight(inner);
      Size frame() => tester.getSize(find.byType(AnimatedContainer));
      double total() => tester.getSize(find.byType(HermesMarkdown)).height;

      expect(frame().height, frameH);
      expect(frame().width, inner);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      final loadingTotal = total();

      l.complete(url, _image(w: 1600, h: 900));
      await settleLoad(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(frame().height, frameH);
      expect(total(), loadingTotal);

      // A failed image takes the same space.
      final f = FakeLoader()..complete(url, null);
      await show(tester, md, loader: f);
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(frame().height, frameH);
      expect(total(), loadingTotal);
    });

    testWidgets('a portrait image narrows its card by its decoded size', (
      tester,
    ) async {
      // A real 2×3 PNG. The bridge's header size says landscape (as for a
      // rotated phone photo); the decoded size wins.
      final portrait = (await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(
          const Rect.fromLTWH(0, 0, 2, 3),
          Paint()..color = const Color(0xFF884422),
        );
        final img = await rec.endRecording().toImage(2, 3);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        return data!.buffer.asUint8List();
      }))!;
      const url = 'https://i.example/p.png';
      final l = FakeLoader()
        ..complete(
          url,
          LinkImage(bytes: portrait, url: url, width: 900, height: 600),
        );
      await show(tester, '![Portrait](https://i.example/p.png)', loader: l);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final frame = tester.getSize(find.byType(AnimatedContainer));
      final fh = MdImageGallery.singleHeight(inner);
      expect(frame.height, fh);
      expect(frame.width, closeTo(fh * 2 / 3, 0.01));
    });

    testWidgets('caption, source page host and source action', (tester) async {
      final taps = <String>[];
      final sem = tester.ensureSemantics();
      await show(
        tester,
        '[![Golden Gate at dusk](https://cdn.example/gg.jpg "The bridge at '
        'dusk")](https://www.news.example/story)',
        onLinkTap: taps.add,
      );
      expect(find.text('The bridge at dusk'), findsOneWidget);
      expect(find.text('news.example'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Image: Golden Gate at dusk'),
        findsOneWidget,
      );
      await tester.tap(find.text('news.example'));
      expect(taps, ['https://www.news.example/story']);
      sem.dispose();
    });

    testWidgets('an unlinked image offers its own host', (tester) async {
      final taps = <String>[];
      await show(
        tester,
        '![Map](https://upload.example/map.png)',
        onLinkTap: taps.add,
      );
      expect(find.text('upload.example'), findsOneWidget);
      await tester.tap(find.text('upload.example'));
      expect(taps, ['https://upload.example/map.png']);
    });

    testWidgets('two images make a pair of equal tiles', (tester) async {
      await show(
        tester,
        '![a](https://i.example/a.png)\n![b](https://i.example/b.png)',
      );
      final tiles = find.byType(AnimatedContainer);
      expect(tiles, findsNWidgets(2));
      final a = tester.getRect(tiles.at(0));
      final b = tester.getRect(tiles.at(1));
      expect(a.top, b.top);
      expect(a.size, b.size);
      expect(a.width, (inner - MdImageGallery.gap) / 2);
      expect(b.left, greaterThan(a.right));
    });

    testWidgets('three or more images scroll sideways', (tester) async {
      final l = await show(
        tester,
        '![a](https://i.example/a.png)\n![b](https://i.example/b.png)\n'
        '![c](https://i.example/c.png)\n![a again](https://i.example/a.png)',
      );
      // Duplicates are shown once.
      expect(find.byType(MdImageTile), findsNWidgets(3));
      expect(
        find.ancestor(
          of: find.byType(MdImageTile).first,
          matching: find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          ),
        ),
        findsOneWidget,
      );
      expect(l.calls.toSet(), {
        'https://i.example/a.png',
        'https://i.example/b.png',
        'https://i.example/c.png',
      });
    });

    testWidgets('a failed image in a pair is dropped, the other stays', (
      tester,
    ) async {
      final l = await show(
        tester,
        '![a](https://i.example/a.png)\n![b](https://blocked.example/b.png)',
      );
      expect(find.byType(MdImageTile), findsNWidgets(2));
      l.complete('https://blocked.example/b.png', null);
      await settleLoad(tester);
      expect(find.byType(MdImageTile), findsOneWidget);
      expect(find.text('Image unavailable'), findsNothing);
      expect(find.text('blocked.example'), findsNothing);
      expect(
        tester.getSize(find.byType(AnimatedContainer)).height,
        MdImageGallery.singleHeight(inner),
      );
    });

    testWidgets('known failures never flash in a strip', (tester) async {
      final l = FakeLoader()..complete('https://i.example/b.png', null);
      await show(
        tester,
        '![a](https://i.example/a.png)\n![b](https://i.example/b.png)\n'
        '![c](https://i.example/c.png)',
        loader: l,
      );
      expect(find.byType(MdImageTile), findsNWidgets(2));
      expect(find.text('Image unavailable'), findsNothing);
    });

    testWidgets('when every image fails, each shows the failure', (
      tester,
    ) async {
      final l = await show(
        tester,
        '![a](https://i.example/a.png)\n![b](https://i.example/b.png)',
      );
      l.complete('https://i.example/a.png', null);
      await settleLoad(tester);
      expect(find.byType(MdImageTile), findsOneWidget);
      l.complete('https://i.example/b.png', null);
      await settleLoad(tester);
      expect(find.byType(MdImageTile), findsNWidgets(2));
      expect(find.text('Image unavailable'), findsNWidgets(2));
    });

    testWidgets('a failed image retries on tap', (tester) async {
      const url = 'https://i.example/c.png';
      final l = FakeLoader()..complete(url, null);
      await show(tester, '![c](https://i.example/c.png)', loader: l);
      await tester.tap(find.text('Image unavailable'));
      await tester.pump();
      expect(l.calls, contains('retry $url'));
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      l.complete(url, _image());
      await settleLoad(tester);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a loaded image opens the viewer with its source', (
      tester,
    ) async {
      const url = 'https://i.example/c.png';
      final l = FakeLoader()..complete(url, _image(w: 10, h: 10));
      await show(
        tester,
        '[![c](https://i.example/c.png)](https://page.example/p)',
        loader: l,
      );
      await tester.tap(find.byType(AnimatedContainer));
      await tester.pumpAndSettle();
      expect(find.byType(MdImageViewer), findsOneWidget);
      expect(find.text('Source: page.example'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(MdImageViewer), findsNothing);
    });

    testWidgets('footnote citations next to an image stay', (tester) async {
      await show(
        tester,
        '![c](https://i.example/c.png)[^1]\n\n[^1]: [Cats](https://cats.example)',
      );
      expect(find.byType(MdImageTile), findsOneWidget);
      expect(find.byType(SourcePill), findsWidgets);
    });

    testWidgets('no overflow at 200 % text in a pair', (tester) async {
      await show(
        tester,
        '[![A very long description of the first picture that wraps]'
        '(https://i.example/a.png "A very long caption that needs two lines '
        'at least")](https://a-really-long-publisher-name.example/x)\n'
        '![b](https://i.example/b.png)',
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('streaming loads an image once, after it is complete', (
      tester,
    ) async {
      setSurface(tester, w);
      final l = FakeLoader();
      final source = ValueNotifier('');
      await tester.pumpWidget(
        host(
          MarkdownImageScope(
            loader: l,
            child: StreamingMarkdown.listenable(
              source: source,
              smoothReveal: false,
            ),
          ),
        ),
      );
      const reply =
          'A photo:\n\n'
          '[![A cat](https://i.example/c.png)](https://page.example/cat)\n\n'
          'More text follows here.';
      for (var i = 1; i <= reply.length; i++) {
        source.value = reply.substring(0, i);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        final text = visibleText(tester);
        expect(text, isNot(contains('[![')), reason: source.value);
        expect(text, isNot(contains('](')), reason: source.value);
      }
      expect(l.calls, ['https://i.example/c.png']);
      expect(find.byType(MdImageTile), findsOneWidget);
      l.complete('https://i.example/c.png', _image());
      await settleLoad(tester);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
