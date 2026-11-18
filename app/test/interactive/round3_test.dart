import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/live/live_link_cards.dart';
import 'package:tove_chat/src/ui/markdown/favicons.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:tove_chat/src/ui/thread/reply_details.dart';

import 'round3_fixtures.dart';

String block(String json) => '```hermes-ui\n$json\n```';

void main() {
  group('schema: entities and news', () {
    test('entities parse with details; news with bylines', () {
      final e =
          parseHermesUi(
                '{"v":1,"type":"entities","items":[{"name":"Ada","sub":"CEO",'
                '"image":"https://img.example.com/a.jpg","about":"Founder.[^1]",'
                '"facts":[{"label":"Born","value":"1970"}],'
                '"links":[{"label":"Bio","url":"https://example.com/bio"}],'
                '"highlights":[{"name":"R1","sub":"2016"}],"ask":"More on Ada"}]}',
              ).element!
              as UiEntities;
      final a = e.items.single;
      expect(a.name, 'Ada');
      expect(a.facts.single.value, '1970');
      expect(a.links.single.url, 'https://example.com/bio');
      expect(a.highlights.single.name, 'R1');
      expect(a.followUp, 'More on Ada');
      expect(e.plainText, 'Ada, CEO');

      final n =
          parseHermesUi(
                '{"v":1,"type":"news","items":[{"title":"Launch",'
                '"url":"https://news.example.com/x","source":"Wire","date":"Nov 12"}]}',
              ).element!
              as UiNews;
      expect(n.items.single.byline, 'Wire · Nov 12');
      expect(n.plainText, 'Launch, Wire · Nov 12');
    });

    test('unsafe URLs and broken limits fall back', () {
      for (final bad in [
        '{"v":1,"type":"entities","items":[{"name":"A","image":"javascript:alert(1)"}]}',
        '{"v":1,"type":"entities","items":[{"name":"A","page":"file:///etc/passwd"}]}',
        '{"v":1,"type":"news","items":[{"title":"T","url":"data:text/html,hi"}]}',
        '{"v":1,"type":"news","items":[{"title":"T"}]}',
        '{"v":1,"type":"entities","items":[]}',
        '{"v":1,"type":"entities","items":[{"sub":"no name"}]}',
      ]) {
        expect(parseHermesUi(bad).ok, isFalse, reason: bad);
      }
    });

    test('the default follow-up names the entity; merge keeps the name', () {
      const a = UiEntity(name: 'Ada', sub: 'CEO');
      expect(a.followUp, 'Tell me more about Ada');
      final m = a.merge(
        const UiEntity(
          name: 'Other',
          about: 'More.',
          facts: [UiFact('X', 'Y')],
        ),
      );
      expect(m.name, 'Ada');
      expect(m.sub, 'CEO');
      expect(m.about, 'More.');
      expect(m.facts.single.label, 'X');
    });

    test('plain text for Read aloud and Share has no JSON', () {
      final text = plainText(newsReply);
      expect(text, contains('Ada Lind, Co-founder and former CEO'));
      expect(text, contains('Lumen announces CEO transition, Lumen Newsroom'));
      expect(text, isNot(contains('"type"')));
    });
  });

  group('details', () {
    test('reads usage, reasoning, timing and tools', () {
      final created = DateTime(2026, 11, 16, 9);
      final d = ReplyDetails.of(
        ChatMessage(
          id: 'm1',
          conversationId: 'c',
          role: MessageRole.assistant,
          text: 'x',
          created: created,
          meta: {
            'effort': 'high',
            'model': 'gpt-5.5',
            'usage': {
              'prompt_tokens': 1200,
              'completion_tokens': 300,
              'completion_tokens_details': {'reasoning_tokens': 120},
              'prompt_tokens_details': {'cached_tokens': 1000},
            },
            'completed_at': created
                .add(const Duration(seconds: 9))
                .millisecondsSinceEpoch,
            'timing': {'first_token_ms': 850},
          },
        ),
        steps: [
          ReplyStep(id: 's1', kind: StepKind.thinking, started: created),
          ReplyStep(
            id: 's2',
            kind: StepKind.tool,
            started: created,
            tool: const StepTool(name: 'web_search'),
          ),
          ReplyStep(
            id: 's3',
            kind: StepKind.tool,
            started: created,
            tool: const StepTool(name: 'web_search'),
          ),
        ],
      );
      expect(d.model, 'gpt-5.5');
      expect(d.totalTokens, 1500); // derived from input + output
      expect(d.reasoningTokens, 120);
      expect(d.cachedTokens, 1000);
      expect(d.firstToken, const Duration(milliseconds: 850));
      expect(d.duration, const Duration(seconds: 9)); // from completed_at
      expect(d.toolCount, 2);
      expect(d.tools, ['web_search']);
      expect(groupedNumber(1234567), '1,234,567');
      expect(shortDuration(const Duration(milliseconds: 14250)), '14 s');
      expect(shortDuration(const Duration(milliseconds: 1840)), '1.8 s');
    });

    testWidgets('More → Details opens the sheet; missing fields say so', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(
        r3Frame(
          AssistantMessage(
            message: reply(
              'Done.',
              meta: {
                'usage': {
                  'prompt_tokens': 10,
                  'completion_tokens': 5,
                  'total_tokens': 15,
                },
              },
            ),
            onRetry: () {},
            onDelete: () {},
          ),
          brightness: Brightness.dark,
          desktop: false,
        ),
      );
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      await tester.tap(find.byTooltip('More'));
      await settle();
      await tester.tap(find.text('Details'));
      await settle();
      expect(find.text('Model'), findsWidgets);
      expect(find.text('15'), findsOneWidget);
      expect(find.text(notAvailable), findsWidgets);
      await tester.tap(find.byTooltip('Copy').last);
      await settle();
      expect(copied, ['msg_r3']);
    });
  });

  group('action row and sources cluster', () {
    testWidgets('reference icons in order; Share shares; cluster at the end', (
      tester,
    ) async {
      phone(tester);
      final shared = <String>[];
      await tester.pumpWidget(
        r3Frame(
          AssistantMessage(
            message: reply(sourcedReply),
            onRetry: () {},
            onDelete: () {},
          ),
          brightness: Brightness.light,
          desktop: false,
          shared: shared,
        ),
      );
      await tester.pumpAndSettle();
      final xs = [
        for (final tip in ['Copy', 'Read aloud', 'Share', 'More'])
          tester.getCenter(find.byTooltip(tip)).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));
      final sources = tester.getCenter(find.text('Sources'));
      expect(sources.dx, greaterThan(xs.last));
      expect(
        (sources.dy - tester.getCenter(find.byTooltip('More')).dy).abs(),
        lessThan(4),
      );
      await tester.tap(find.byTooltip('Share'));
      await tester.pump();
      expect(shared.single, startsWith('I would install'));

      // Three favicons (from the bridge loader), then the sheet.
      final cluster = find.descendant(
        of: find.byType(LiveSourcesPill),
        matching: find.byType(SiteFavicon),
      );
      expect(cluster, findsNWidgets(3));
      expect(find.byType(SiteLetterTile), findsNothing);
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      expect(find.byType(LiveSiteCard), findsNWidgets(3));
      expect(find.text('OpenSSH for Windows'), findsOneWidget);
    });

    testWidgets('no favicon: letter tiles', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        r3Frame(
          AssistantMessage(
            message: reply(sourcedReply),
            onRetry: null,
            onDelete: () {},
          ),
          brightness: Brightness.dark,
          desktop: false,
          images: FakeBridgeImages(favicons: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SiteLetterTile), findsWidgets);
    });
  });

  group('entities and news', () {
    testWidgets('a card opens its sheet; Follow up sends; links open', (
      tester,
    ) async {
      phone(tester, height: 2400);
      final sent = <String>[];
      final opened = <String>[];
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            onSend: sent.add,
            onOpenLink: opened.add,
            child: const MarkdownBody(newsReply),
          ),
          brightness: Brightness.dark,
          desktop: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ada Lind'), findsOneWidget);
      expect(
        find.text('Lumen announces CEO transition'),
        findsNothing,
        reason: 'the headline is a rich text with its arrow',
      );
      await tester.tap(find.textContaining('Lumen announces CEO'));
      await tester.pumpAndSettle();
      expect(opened, ['https://news.example.com/ceo']);

      await tester.tap(find.text('Ada Lind'));
      await tester.pumpAndSettle();
      expect(find.text('Key facts'), findsOneWidget);
      expect(
        find.textContaining('grew it from a lab spin-out'),
        findsOneWidget,
      );
      // The summary's citation resolves from the reply's footnotes.
      expect(find.text('CEO transition'), findsOneWidget);
      await tester.tap(find.text('Follow up'));
      await tester.pumpAndSettle();
      expect(sent, ['Tell me more about Ada Lind']);
      expect(find.text('Key facts'), findsNothing);
    });

    testWidgets('details fetched by the app fill the sheet', (tester) async {
      phone(tester, height: 1600);
      final more = Completer<UiEntity?>();
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            onEntityDetails: (e) => more.future,
            child: MarkdownBody(
              block(
                '{"v":1,"type":"entities","items":[{"name":"Omar Reyes","sub":"Interim CEO"}]}',
              ),
            ),
          ),
          brightness: Brightness.light,
          desktop: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Omar Reyes'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.bySemanticsLabel('Loading details'), findsOneWidget);
      more.complete(
        parseUiEntity({
          'name': 'Omar Reyes',
          'about': 'Finance chief since 2019.',
          'facts': [
            {'label': 'Joined', 'value': '2019'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Finance chief since 2019.'), findsOneWidget);
      expect(find.text('2019'), findsOneWidget);
      expect(find.text('Interim CEO'), findsNWidgets(2)); // card and sheet
    });

    testWidgets('200 % text: no overflow on phone', (tester) async {
      phone(tester, height: 6000);
      await tester.pumpWidget(
        r3Frame(
          AssistantMessage(
            message: reply(newsReply),
            onRetry: () {},
            onDelete: () {},
          ),
          brightness: Brightness.dark,
          desktop: false,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('while streaming, a half entity block is a placeholder', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(
        r3Frame(
          const MarkdownBody(
            'Intro.\n\n```hermes-ui\n{"v":1,"type":"entities","items":[{"name":"Ad',
            streaming: true,
          ),
          brightness: Brightness.dark,
          desktop: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(UiPlaceholder), findsOneWidget);
      expect(find.textContaining('"name"'), findsNothing);
    });
  });

  group('favicons through the bridge', () {
    test(
      '/api/favicon when present; link preview on an older bridge',
      () async {
        final calls = <String>[];
        final png = base64Encode(const [137, 80, 78, 71, 1, 2, 3]);
        Future<http.Response> handler(
          http.Request r, {
          required bool route,
        }) async {
          calls.add('${r.url.path}?${r.url.query}');
          if (r.url.path.endsWith('/api/favicon')) {
            if (!route) return http.Response('Not Found', 404);
            return http.Response(
              jsonEncode({'favicon': 'data:image/png;base64,$png'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'url': r.url.queryParameters['url'],
              'kind': 'page',
              'favicon': 'data:image/x-icon;base64,$png',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        final old = BridgeImageLoader(
          baseUrl: Uri.parse('https://bridge.example/'),
          accessKey: 'k',
          client: MockClient((r) => handler(r, route: false)),
        );
        final a = await old.loadFavicon('www.Example.com');
        expect(a.image, isNotNull);
        expect(old.faviconRoute, isFalse);
        await old.loadFavicon('other.example.org');
        expect(calls, [
          '/api/favicon?host=example.com',
          '/api/link-preview?url=https%3A%2F%2Fexample.com%2F',
          '/api/link-preview?url=https%3A%2F%2Fother.example.org%2F',
        ]);
        // Cached per host.
        expect(old.peekFavicon('example.com')?.image, isNotNull);
        await old.loadFavicon('example.com');
        expect(calls, hasLength(3));

        calls.clear();
        final current = BridgeImageLoader(
          baseUrl: Uri.parse('https://bridge.example/'),
          accessKey: 'k',
          client: MockClient((r) => handler(r, route: true)),
        );
        expect((await current.loadFavicon('example.com')).image, isNotNull);
        expect(current.faviconRoute, isTrue);
        expect(calls, ['/api/favicon?host=example.com']);
      },
    );

    test('parseFaviconBody accepts only signature-checked image types', () {
      List<int> body(String url) => utf8.encode(jsonEncode({'favicon': url}));
      expect(
        parseFaviconBody(body('data:image/svg+xml;base64,PHN2Zz4=')),
        isNull,
      );
      expect(parseFaviconBody(body('https://example.com/icon.png')), isNull);
      expect(
        parseFaviconBody(body('data:image/png;base64,iVBORw==')),
        isNotNull,
      );
    });
  });

  group('typography per platform', () {
    test('typefaces', () {
      HermesTypeface on(TargetPlatform p, {bool web = false}) =>
          HermesTypeface.forPlatform(p, web: web);
      expect(on(TargetPlatform.android), HermesTypeface.phone);
      expect(on(TargetPlatform.iOS), HermesTypeface.ios);
      expect(on(TargetPlatform.windows), HermesTypeface.windows);
      expect(on(TargetPlatform.macOS), HermesTypeface.macos);
      expect(on(TargetPlatform.linux), HermesTypeface.linux);
      expect(on(TargetPlatform.windows, web: true), HermesTypeface.web);
    });

    test('desktop and web: 16/26, bold is semibold; phones 17/26 700', () {
      final win = HermesTokens.darkTokens.withType(HermesTypeface.windows);
      expect(win.body.fontFamily, 'Segoe UI');
      expect(win.body.fontSize, 16);
      expect(win.body.fontSize! * win.body.height!, closeTo(26, 1e-9));
      expect(win.body.fontWeight, FontWeight.w400);
      expect(win.body.fontVariations, isNull);
      expect(win.body.letterSpacing, 0);
      expect(win.bodyStrong.fontWeight, FontWeight.w600);
      expect(win.h2.fontWeight, FontWeight.w600);
      expect(win.bodyEm.fontStyle, FontStyle.italic);

      final web = HermesTokens.darkTokens.withType(HermesTypeface.web);
      expect(web.body.fontFamily, 'HermesSans');
      expect(web.body.fontSize, 16);
      expect(web.body.fontSize! * web.body.height!, closeTo(26, 1e-9));
      expect(
        web.bodyStrong.fontVariations,
        contains(const FontVariation('wght', 600)),
      );

      const phone = HermesTokens.darkTokens;
      expect(phone.body.fontSize, 17);
      expect(phone.bodyStrong.fontWeight, FontWeight.w700);
      expect(MarkdownStyle.fromTokens(win).strongWeight, 600);
      expect(MarkdownStyle.fromTokens(phone).strongWeight, 700);
    });

    test('the theme uses the platform family', () {
      final t = buildTheme(Brightness.dark, type: HermesTypeface.macos);
      expect(t.textTheme.bodyLarge!.fontFamily, '.AppleSystemUIFont');
      expect(t.extension<HermesTokens>()!.typeface, HermesTypeface.macos);
      // Tests run as Android: the bundled font.
      expect(
        buildTheme(Brightness.dark).extension<HermesTokens>()!.typeface,
        HermesTypeface.phone,
      );
    });
  });
}

void phone(WidgetTester tester, {double height = 1400}) {
  tester.view.physicalSize = Size(412, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Renders markdown statically, or as a stream when [streaming].
class MarkdownBody extends StatelessWidget {
  const MarkdownBody(this.text, {super.key, this.streaming = false});
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) => streaming
      ? StreamingMarkdown(text: text, isStreaming: true)
      : HermesMarkdown(text: text);
}
