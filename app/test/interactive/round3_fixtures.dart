import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/markdown/favicons.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/markdown/place_info.dart';
import 'package:tove_chat/src/ui/theme/motion.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:tove_chat/src/ui/thread/message_actions.dart';

/// A news-style reply (round 3, after the reference's structure) about a
/// fictional company. Every address is an example domain.
const newsReply = '''Sure. Here's the latest.

Big news: Ada Lind has stepped down as CEO of Lumen Robotics after 12 years. The board named the CFO, Omar Reyes, interim CEO while it searches for a successor. Results are due on November 20.

## Lumen Robotics CEO — latest update

<small>November 15, 2026</small>

**Ada Lind has stepped down as Lumen's CEO.** The company announced her departure on November 12, ending a 12-year run.[^1][^2]

```hermes-ui
{"v":1,"type":"entities","items":[
 {"name":"Ada Lind","sub":"Co-founder and former CEO","image":"https://img.example.com/ada.jpg","page":"https://example.com/people/ada",
  "about":"Ada Lind co-founded **Lumen Robotics** in 2014 and grew it from a lab spin-out into a global supplier of warehouse robots.[^1]",
  "facts":[{"label":"Role","value":"Co-founder, former CEO"},{"label":"CEO","value":"2014 – 2026"}],
  "highlights":[{"name":"Lumen R1","sub":"2016","image":"https://img.example.com/r1.jpg"},{"name":"Series C","sub":"2021","image":"https://img.example.com/c.jpg"}],
  "links":[{"label":"Company profile","url":"https://example.com/about"}]},
 {"name":"Omar Reyes","sub":"Interim CEO and CFO","image":"https://img.example.com/omar.jpg"}]}
```

### What happened?

- **Resignation:** The board accepted Lind's resignation on November 11.[^1]
- **New leadership:** Omar Reyes leads the company while the board searches for a permanent CEO.[^2]
- **What's next:** Quarterly results are due on November 20.[^3][^2]

### Latest news

```hermes-ui
{"v":1,"type":"news","items":[
 {"title":"Lumen announces CEO transition","url":"https://news.example.com/ceo","source":"Lumen Newsroom","date":"November 12","image":"https://img.example.com/hq.jpg"},
 {"title":"Meet Lumen's interim CEO","url":"https://wire.example.org/reyes","source":"Example Wire","date":"November 13","image":"https://img.example.com/omar.jpg"}]}
```

[^1]: [CEO transition](https://news.example.com/ceo) — Lumen Newsroom
[^2]: [Interim CEO named](https://wire.example.org/reyes) — Example Wire
[^3]: [Investor calendar](https://investors.example.net/calendar) — Lumen IR
''';

/// A short reply whose sources fill the action row's cluster.
const sourcedReply = '''I would install the remote agent on your core server alongside OpenSSH. That gives the assistant terminal access and you one place to manage every computer.[^1]

Start with the native OpenSSH install in section 2; it assumes administrator access.[^2][^3]

[^1]: [OpenSSH for Windows](https://learn.example.com/openssh) — Example Learn
[^2]: [Remote agent docs](https://docs.example.org/agent) — Example Docs
[^3]: [SSH config](https://code.example.net/ssh) — Example Code
''';

Uint8List _png(int w, int h, int seed, {bool round = false}) {
  final rnd = math.Random(seed);
  final a = img.ColorRgb8(
    rnd.nextInt(200),
    rnd.nextInt(200),
    120 + rnd.nextInt(120),
  );
  final b = img.ColorRgb8(
    200 + rnd.nextInt(55),
    180 + rnd.nextInt(60),
    rnd.nextInt(120),
  );
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final t = (x + y) / (w + h);
      final c = img.ColorRgb8(
        (a.r * (1 - t) + b.r * t).round(),
        (a.g * (1 - t) + b.g * t).round(),
        (a.b * (1 - t) + b.b * t).round(),
      );
      im.setPixel(x, y, c);
    }
  }
  // A darker disc in the middle, like a subject or a logo mark.
  img.fillCircle(
    im,
    x: w ~/ 2,
    y: (h * (round ? 0.5 : 0.42)).round(),
    radius: (math.min(w, h) * (round ? 0.3 : 0.24)).round(),
    color: img.ColorRgb8(30, 30, 40),
  );
  return img.encodePng(im);
}

/// Pictures and favicons from memory, like the bridge loader with its
/// cache already warm.
class FakeBridgeImages
    implements MarkdownImageLoader, FaviconSource, PlaceInfoSource {
  FakeBridgeImages({this.favicons = true});

  final bool favicons;
  final _cache = <String, LinkImageResult>{};

  LinkImageResult _make(String key, int w, int h, {bool round = false}) =>
      _cache[key] ??= LinkImageResult(
        LinkImage(
          bytes: _png(w, h, key.hashCode & 0xffff, round: round),
          url: key,
          width: w,
          height: h,
        ),
      );

  @override
  LinkImageResult? peek(String url) => _make(url, 160, 160);

  @override
  Future<LinkImageResult> load(String url, {bool retry = false}) =>
      SynchronousFuture(peek(url)!);

  @override
  LinkImageResult? peekFavicon(String host) => favicons
      ? _make('icon:${faviconHost(host)}', 32, 32, round: true)
      : const LinkImageResult(null);

  @override
  Future<LinkImageResult> loadFavicon(String host) =>
      SynchronousFuture(peekFavicon(host)!);

  /// Places the bridge "knows" (neutral sample data, see [samplePlaces]).
  @override
  PlaceInfo? peekPlace(String id) => samplePlaces[id];

  @override
  Future<PlaceInfo?> placeInfo(String id) =>
      SynchronousFuture(samplePlaces[id]);

  /// No tiles in tests: the map draws its plain grid.
  @override
  Future<MapTiles?> mapTiles() => SynchronousFuture(null);
}

/// Neutral sample places for place cards and maps (invented names, numbers
/// and positions).
const samplePlaces = {
  'place:sample-clinic-0001': PlaceInfo(
    id: 'place:sample-clinic-0001',
    name: 'Sample Mind Clinic',
    category: 'Psychiatry',
    subtitle: 'Psychiatry · Example Street',
    lat: 13.0339,
    lng: 80.2686,
    distanceKm: 0.4,
    phone: '+91 00000 00001',
    website: 'https://clinic.example/adhd',
    hours: 'Mo-Sa 09:00-20:00; Su off',
    openNow: true,
    photo: 'https://images.example/clinic.jpg',
  ),
  'place:sample-centre-0002': PlaceInfo(
    id: 'place:sample-centre-0002',
    name: 'Example Neuro Centre',
    category: 'Psychology',
    subtitle: 'Psychology · Sample Road',
    lat: 13.0212,
    lng: 80.2565,
    distanceKm: 2.1,
    phone: '+91 00000 00002',
  ),
  'place:sample-health-0003': PlaceInfo(
    id: 'place:sample-health-0003',
    name: 'Placeholder Health Hospital',
    category: 'Hospital',
    subtitle: 'Hospital · Test Lane',
    lat: 13.0420,
    lng: 80.2490,
    distanceKm: 1.6,
    phone: '+91 00000 00003',
    website: 'https://hospital.example/',
    openNow: false,
    hours: 'Mo-Fr 10:00-17:00',
  ),
};

class FakeReadAloud extends ChangeNotifier implements ReadAloud {
  @override
  bool get available => true;
  @override
  String? get reading => null;
  @override
  Future<void> toggle(ChatMessage message) async {}
}

ChatMessage reply(
  String text, {
  Map<String, dynamic> meta = const {},
  String id = 'msg_r3',
}) => ChatMessage(
  id: id,
  conversationId: 'c1',
  role: MessageRole.assistant,
  text: text,
  created: DateTime(2026, 11, 16, 9, 41, 7),
  meta: meta,
);

const goldenKey = ValueKey('r3-golden');

/// Phone (412 dp, Roboto Flex 17/26) or desktop (760 dp, 16/26: the web and
/// desktop metrics) frame with the thread gutter, a warm image loader and
/// fixed motion and render policy.
Widget r3Frame(
  Widget child, {
  required Brightness brightness,
  required bool desktop,
  double textScale = 1,
  MarkdownImageLoader? images,
  List<String>? shared,
  bool sheet = false,
}) {
  final theme = buildTheme(
    brightness,
    type: desktop ? HermesTypeface.web : HermesTypeface.phone,
  );
  final t = theme.extension<HermesTokens>()!;
  final width = sheet ? (desktop ? 520.0 : 392.0) : (desktop ? 760.0 : 412.0);
  final gutter = sheet ? 0.0 : (desktop ? 20.0 : 16.0);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: MotionScope(
        reduce: true,
        child: RenderPolicyScope(
          policy: RenderPolicy(
            blur: false,
            shaderOrb: false,
            liveMask: true,
            monitor: false,
          ),
          child: c!,
        ),
      ),
    ),
    home: Scaffold(
      body: MarkdownImageScope(
        loader: images ?? FakeBridgeImages(),
        child: MessageActions(
          share: (text) async => shared?.add(text),
          notify: (_) {},
          readAloud: FakeReadAloud(),
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topCenter,
              child: RepaintBoundary(
                key: goldenKey,
                child: Container(
                  width: width,
                  decoration: BoxDecoration(
                    color: sheet ? t.sheetFallback : t.bg,
                    borderRadius: sheet
                        ? BorderRadius.circular(Rad.sheet)
                        : null,
                  ),
                  padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 16),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Decodes every picture on screen (decoding is real async work).
Future<void> settleImages(WidgetTester tester) async {
  for (var round = 0; round < 2; round++) {
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final image = (e.widget as Image).image;
        final c = Completer<void>();
        final stream = image.resolve(createLocalImageConfiguration(e));
        late final ImageStreamListener l;
        l = ImageStreamListener(
          (_, _) {
            if (!c.isCompleted) c.complete();
            stream.removeListener(l);
          },
          onError: (_, _) {
            if (!c.isCompleted) c.complete();
          },
        );
        stream.addListener(l);
        await c.future.timeout(const Duration(seconds: 5), onTimeout: () {});
      }
    });
    await tester.pump(const Duration(milliseconds: 300));
  }
}
