import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/entity_info.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';

import 'round3_fixtures.dart';

String block(String json) => '```hermes-ui\n$json\n```';

const _huang = EntityInfo(
  title: 'Jensen Huang',
  description: 'Taiwanese-American businessman',
  extract: 'Jensen Huang is an engineer who co-founded Nvidia.',
  image: 'https://thumb.wikimedia.org/x/330px-J.jpg',
  originalImage: 'https://upload.wikimedia.org/x/J.jpg',
  page: 'https://en.wikipedia.org/wiki/Jensen_Huang',
);

/// The round 3 fake plus entity info and page pictures.
class FakeInfoImages extends FakeBridgeImages
    implements EntityInfoSource, PageImageSource {
  FakeInfoImages({this.pages = const {}}) : super(favicons: false);

  final Set<String> pages;
  final asked = <String>[];
  final loaded = <String>[];

  @override
  LinkImageResult? peek(String url) => null;

  @override
  Future<LinkImageResult> load(String url, {bool retry = false}) {
    loaded.add(url);
    return SynchronousFuture(super.peek(url)!);
  }

  @override
  EntityInfo? peekEntityInfo(String name, {String? hint}) => null;

  @override
  Future<EntityInfo?> entityInfo(String name, {String? hint}) {
    asked.add('$name|$hint');
    return SynchronousFuture(name == 'Jensen Huang' ? _huang : null);
  }

  @override
  LinkImageResult? peekPageImage(String pageUrl) => null;

  @override
  Future<LinkImageResult> loadPageImage(String pageUrl) => SynchronousFuture(
    pages.contains(pageUrl)
        ? super.peek('page:$pageUrl')!
        : const LinkImageResult(null),
  );
}

void main() {
  group('cards, news and the sheet', () {
    testWidgets('an entity without a picture gets the Wikipedia one; the '
        'sheet shows description, summary and Read on Wikipedia', (
      tester,
    ) async {
      phone(tester, height: 1800);
      final images = FakeInfoImages();
      final opened = <String>[];
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            onOpenLink: opened.add,
            child: MarkdownBody(
              block(
                '{"v":1,"type":"entities","items":[{"name":"Jensen Huang",'
                '"sub":"NVIDIA co-founder and former CEO"},{"name":"Nobody"}]}',
              ),
            ),
          ),
          brightness: Brightness.dark,
          desktop: false,
          images: images,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        images.asked,
        contains('Jensen Huang|NVIDIA co-founder and former CEO'),
      );
      expect(images.loaded, contains(_huang.image));
      // The letter tile stays only where nothing was found.
      expect(find.text('N'), findsOneWidget);
      expect(find.text('J'), findsNothing);

      await tester.tap(find.text('Jensen Huang'));
      await tester.pumpAndSettle();
      expect(images.loaded, contains(_huang.originalImage));
      expect(find.textContaining('co-founded Nvidia'), findsOneWidget);
      expect(find.textContaining('Taiwanese-American'), findsOneWidget);
      expect(find.text('Read on Wikipedia'), findsOneWidget);
      await tester.tap(find.text('Read on Wikipedia'));
      await tester.pumpAndSettle();
      expect(opened, [_huang.page]);
    });

    testWidgets('a pull down on the sheet body dismisses it', (tester) async {
      phone(tester, height: 1800);
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            child: MarkdownBody(
              block(
                '{"v":1,"type":"entities","items":[{"name":"Jensen Huang"}]}',
              ),
            ),
          ),
          brightness: Brightness.light,
          desktop: false,
          images: FakeInfoImages(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jensen Huang'));
      await tester.pumpAndSettle();
      expect(find.text('Read on Wikipedia'), findsOneWidget);
      // On the summary text, well below the header handle.
      await tester.fling(
        find.textContaining('co-founded Nvidia'),
        const Offset(0, 400),
        1500,
      );
      await tester.pumpAndSettle();
      expect(find.text('Read on Wikipedia'), findsNothing);
    });

    testWidgets('a short pull on the body springs back', (tester) async {
      phone(tester, height: 1800);
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            child: MarkdownBody(
              block(
                '{"v":1,"type":"entities","items":[{"name":"Jensen Huang"}]}',
              ),
            ),
          ),
          brightness: Brightness.light,
          desktop: false,
          images: FakeInfoImages(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jensen Huang'));
      await tester.pumpAndSettle();
      final g = await tester.startGesture(
        tester.getCenter(find.textContaining('co-founded Nvidia')),
      );
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('Read on Wikipedia'), findsOneWidget);
    });

    testWidgets('news rows take the article picture when found, and no '
        'empty frame when not', (tester) async {
      phone(tester, height: 1600);
      await tester.pumpWidget(
        r3Frame(
          const HermesUiScope(
            child: MarkdownBody(
              '```hermes-ui\n{"v":1,"type":"news","items":['
              '{"title":"With picture","url":"https://n.example/a","source":"A"},'
              '{"title":"Without","url":"https://n.example/b","source":"B"}]}\n```',
            ),
          ),
          brightness: Brightness.dark,
          desktop: false,
          images: FakeInfoImages(pages: {'https://n.example/a'}),
        ),
      );
      await tester.pumpAndSettle();
      final frames = find.byType(UiRemoteImage);
      expect(frames, findsNWidgets(2));
      final sizes = [
        for (final e in frames.evaluate()) (e.renderObject! as RenderBox).size,
      ];
      expect(sizes.where((s) => s.width > 50), hasLength(1));
      expect(sizes.where((s) => s == Size.zero), hasLength(1));
    });
  });
}

void phone(WidgetTester tester, {double height = 1400}) {
  tester.view.physicalSize = Size(412, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class MarkdownBody extends StatelessWidget {
  const MarkdownBody(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => HermesMarkdown(text: text);
}
