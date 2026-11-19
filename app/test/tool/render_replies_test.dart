// Renders answer-quality eval replies (server/eval/run_eval.py results) as
// phone-sized PNGs, one per turn: the question bubble and the reply, drawn
// by the real widgets with real pictures (fetched directly; place details
// from the results' saved /api/places/info). Skipped unless TOVE_RENDER_IN
// is set:
//
//   TOVE_RENDER_IN=/path/results.json TOVE_RENDER_OUT=/path/renders \
//   [TOVE_RENDER_THEME=light|dark|both] [TOVE_RENDER_ONLY=adhd,dentist] \
//   [TOVE_RENDER_QUIZ="Often,Sometimes"] \
//   flutter test test/tool/render_replies_test.dart
//
// TOVE_RENDER_QUIZ answers a Quiz in the last turn first (e.g. two answers
// show question 3 of 6) and adds a "-quiz" render.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/favicons.dart';
import 'package:tove_chat/src/ui/markdown/md_images.dart';
import 'package:tove_chat/src/ui/markdown/place_info.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../interactive/round3_fixtures.dart';
import '../markdown/golden_harness.dart' show loadReplyFonts;

/// Pictures fetched straight from the web (the bridge's job in the app),
/// places from the saved bridge answers.
class NetImages implements MarkdownImageLoader, FaviconSource, PlaceInfoSource {
  NetImages(this.places);
  final Map<String, PlaceInfo> places;
  final _cache = <String, LinkImageResult>{};
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..userAgent = 'ToveRender/1.0 (eval renders)';

  Future<void> warm(Iterable<String> urls) async {
    await Future.wait([
      for (final u in urls)
        if (!_cache.containsKey(u)) _fetch(u),
    ]);
  }

  Future<void> _fetch(String url) async {
    LinkImage? image;
    try {
      final req = await _client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      req.headers.set('Accept', 'image/webp,image/jpeg,image/png,image/*');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final bytes = await consolidateHttpClientResponseBytes(res);
      final type = res.headers.contentType?.mimeType ?? '';
      if (res.statusCode == 200 &&
          type.startsWith('image/') &&
          !type.contains('svg') &&
          bytes.length < 8 << 20) {
        image = LinkImage(bytes: bytes, url: url);
      }
    } catch (_) {}
    _cache[url] = LinkImageResult(image);
  }

  @override
  LinkImageResult? peek(String url) => _cache[url];

  @override
  Future<LinkImageResult> load(String url, {bool retry = false}) =>
      SynchronousFuture(_cache[url] ?? const LinkImageResult(null));

  @override
  LinkImageResult? peekFavicon(String host) => const LinkImageResult(null);

  @override
  Future<LinkImageResult> loadFavicon(String host) =>
      SynchronousFuture(const LinkImageResult(null));

  @override
  PlaceInfo? peekPlace(String id) => places[id];

  @override
  Future<PlaceInfo?> placeInfo(String id) => SynchronousFuture(places[id]);

  @override
  Future<MapTiles?> mapTiles() => SynchronousFuture(null);
}

final _urls = RegExp(
  r'https?://[^\s"\)\]<>]+\.(?:jpe?g|png|webp|gif)(?:\?[^\s"\)\]<>]*)?',
  caseSensitive: false,
);

void main() {
  final input = Platform.environment['TOVE_RENDER_IN'];
  final outDir = Platform.environment['TOVE_RENDER_OUT'] ?? 'renders';
  final theme = Platform.environment['TOVE_RENDER_THEME'] ?? 'light';
  final only = (Platform.environment['TOVE_RENDER_ONLY'] ?? '')
      .split(',')
      .where((x) => x.isNotEmpty)
      .toSet();
  final quiz = (Platform.environment['TOVE_RENDER_QUIZ'] ?? '')
      .split(',')
      .where((x) => x.isNotEmpty)
      .toList();
  if (input == null) {
    test('render eval replies (set TOVE_RENDER_IN)', () {}, skip: true);
    return;
  }
  final data = jsonDecode(File(input).readAsStringSync()) as Map;
  final cases = [
    for (final c in data['cases'] as List)
      if (only.isEmpty || only.contains((c as Map)['id'])) c as Map,
  ];
  final brightness = [
    if (theme != 'dark') Brightness.light,
    if (theme != 'light') Brightness.dark,
  ];
  setUpAll(() async {
    await loadReplyFonts();
    HttpOverrides.global = null; // real network for pictures
    Directory(outDir).createSync(recursive: true);
  });

  for (final c in cases) {
    final turns = (c['turns'] as List).cast<Map>();
    for (final (i, t) in turns.indexed) {
      for (final b in brightness) {
        final name =
            '${c['id']}${turns.length > 1 ? '-${i + 1}' : ''}-${b.name}';
        final withQuiz = quiz.isNotEmpty && i == turns.length - 1;
        testWidgets('render $name', (tester) async {
          final places = <String, PlaceInfo>{
            for (final e in ((t['places'] as Map?) ?? const {}).entries)
              '${e.key}': ?PlaceInfo.fromJson(e.value),
          };
          final images = NetImages(places);
          final text = (t['text'] as String?)?.trim().isNotEmpty == true
              ? t['text'] as String
              : '_(no reply: ${t['error'] ?? 'empty'})_';
          await tester.runAsync(
            () => images.warm([
              ..._urls.allMatches(text).map((m) => m[0]!),
              for (final p in places.values) ?p.photo,
            ]),
          );
          tester.view.physicalSize = const Size(412, 12000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            r3Frame(
              HermesUiScope(
                onSend: (_) {},
                onOpenLink: (_) {},
                stateKey: 'render-$name',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UserBubble(
                      message: ChatMessage(
                        id: 'u$i',
                        conversationId: 'c',
                        role: MessageRole.user,
                        text: t['user'] as String,
                        created: DateTime(2026, 11, 19, 10),
                      ),
                    ),
                    const SizedBox(height: 20),
                    AssistantMessage(
                      message: reply(text, id: 'r$i'),
                      onRetry: () {},
                      onDelete: () {},
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              brightness: b,
              desktop: false,
              images: images,
            ),
          );
          await tester.pump(const Duration(milliseconds: 900));
          await settleImages(tester);
          await tester.pump(const Duration(milliseconds: 300));
          await _capture(tester, '$outDir/$name.png');
          if (withQuiz) {
            for (final o in quiz) {
              final f = find.bySemanticsLabel(RegExp('^$o, option '));
              if (f.evaluate().isEmpty) break;
              await tester.tap(f.first);
              await tester.pump(const Duration(milliseconds: 400));
            }
            await _capture(tester, '$outDir/$name-quiz.png');
          }
          tester.takeException();
        });
      }
    }
  }
}

Future<void> _capture(WidgetTester tester, String path) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(goldenKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png!.buffer.asUint8List();
  });
  File(path).writeAsBytesSync(bytes!);
}
