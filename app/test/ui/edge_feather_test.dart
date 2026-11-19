import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/shell/edge_feather.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/thread_view.dart';

import '../fakes.dart';
import 'test_harness.dart';

class _NoFeedback implements FeedbackSink {
  @override
  void haptic(Haptic h) {}
  @override
  void cue(Cue c) {}
}

/// Synthetic fixture: a long structured reply of the shape the bridge prompt
/// now asks for (lead, headings, bold-label list, table, code, footnote).
const _longReply = '''
Methylphenidate SR is a sustained-release stimulant used mainly for ADHD.[^1]

## At a glance

- **Medicine:** Methylphenidate hydrochloride
- **Strength:** 10 mg
- **Type:** Sustained-release (SR) tablet
- **Primary use:** Treatment of ADHD

## How it works

It increases dopamine and noradrenaline activity, which can help:

1. Focus and concentration
2. Attention span
3. Impulse control

| Effect | How common |
| --- | --- |
| Reduced appetite | Common |
| Trouble sleeping | Common |
| Headache | Common |

```bash
echo "take as prescribed"
```

**Important:** do not crush or chew a sustained-release tablet.

It is a prescription-only medicine; follow the dose your doctor set, and ask before changing it.

Common side effects also include dry mouth, nervousness and a faster heart rate, which are usually checked during treatment.

[^1]: [About methylphenidate](https://example.com/methylphenidate) — Example.
''';

Map<String, dynamic> _conv(String id, String title) => {
  'id': id,
  'title': title,
  'title_source': 'user',
  'pinned': false,
  'kind': 'text',
  'created': 1794691021626,
  'updated': 1794691021626,
  'preview': '',
  'message_count': 2,
};

Map<String, dynamic> _stored(String id, String role, String text) => {
  'id': id,
  'conversation_id': 'c1',
  'role': role,
  'text': text,
  'source': 'text',
  'status': 'complete',
  'created': 1794691021626,
  'client_id': null,
  'meta': <String, dynamic>{},
};

/// The header and composer feathers (the thread scrolls under both and fades
/// toward the screen edges), and the structured-reply rendering they frame.
void main() {
  late FakeBridge bridge;
  late CallController call;
  late SettingsController settings;
  const statusBar = 40.0;
  const screen = Size(412, 915);

  setUpAll(loadAppFonts);

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boot(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    void Function(FakeBridge)? setup,
  }) async {
    phoneSize(tester, size: screen);
    tester.view.padding = const FakeViewPadding(top: statusBar, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: statusBar, bottom: 24);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    bridge = FakeBridge()..chatEnabled = true;
    setup?.call(bridge);
    final prefs = MemoryPrefsStore();
    if (brightness == Brightness.light) prefs.values['theme'] = 'light';
    settings = SettingsController(keys: MemoryKeyStore(testKey), prefs: prefs);
    final link = LiveLink();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: FakeTransport.new,
      platform: FakePlatform(supported: false),
      voice: () => settings.voice,
      conversationId: () => link.conversationId,
      timings: fastTimings,
      desktop: true,
    );
    addTearDown(call.dispose);
    await tester.pumpWidget(
      HermesApp(
        settings: settings,
        call: call,
        liveLink: link,
        verify: (u, k) async {},
        chatApi: (s) => ChatApi(
          baseUrl: Uri.parse('https://bridge.test:9476'),
          accessKey: s.accessKey,
          client: bridge.client,
        ),
        feedbackSink: _NoFeedback(),
        renderPolicy: RenderPolicy(
          blur: false,
          shaderOrb: false,
          liveMask: true,
          monitor: false,
        ),
      ),
    );
    await settings.load();
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await tester.pump();
  }

  /// Opens a stored chat whose last reply is [_longReply].
  Future<void> openLong(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 600);
    await tester.tap(find.text('Medicine'));
    await tester.runAsync(() => settle(20));
    await advance(tester, 800);
  }

  void seedLong(FakeBridge b) {
    b.conversations.add(_conv('c1', 'Medicine'));
    b.stored['c1'] = [
      _stored('u0', 'user', 'What is this medicine?'),
      _stored('a0', 'assistant', _longReply),
    ];
  }

  Finder threadScrollable() => find
      .descendant(
        of: find.byType(ThreadView),
        matching: find.byType(Scrollable),
      )
      .first;

  double offset(WidgetTester tester) =>
      tester.state<ScrollableState>(threadScrollable()).position.pixels;

  Rect feather(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  Rect? composerPill(WidgetTester tester) =>
      tester.getRect(find.byType(TextField));

  /// Writes a stamped render of the whole screen when TOVE_QA_RENDER_DIR is
  /// set (QA evidence only; the suite itself never writes files).
  Future<void> render(WidgetTester tester, String name, String note) async {
    final dir = Platform.environment['TOVE_QA_RENDER_DIR'];
    if (dir == null || dir.isEmpty) return;
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final size = view.size;
    await tester.runAsync(() async {
      final shot = await layer.toImage(Offset.zero & size, pixelRatio: 1);
      const band = 60.0;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(shot, Offset.zero, Paint());
      c.drawRect(
        Rect.fromLTWH(0, size.height, size.width, band),
        Paint()..color = const Color(0xFFFFD54F),
      );
      final pb =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(fontSize: 11, fontFamily: 'Roboto'),
            )
            ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
            ..addText(
              'SYNTHETIC FLUTTER TEST RENDER (not a device capture) '
              '2026-11-15 · $name\n$note',
            );
      final para = pb.build()
        ..layout(ui.ParagraphConstraints(width: size.width - 12));
      c.drawParagraph(para, Offset(6, size.height + 4));
      final img = await rec.endRecording().toImage(
        size.width.round(),
        (size.height + band).round(),
      );
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  group('feather profile', () {
    final top = EdgeFeather.topStops(
      statusBar: statusBar,
      bar: 56,
      underBar: ThreadView.underBar,
    );
    final bottom = EdgeFeather.bottomStops(composerExtent: 100);

    test('the header feather fades from the top edge to nothing where the '
        'first message rests, and is never opaque', () {
      expect(top.last.at, statusBar + 56 + ThreadView.underBar);
      expect(EdgeFeather.alphaAt(top, 0), EdgeFeather.topEdge);
      expect(EdgeFeather.alphaAt(top, top.last.at), 0);
      var last = 2.0;
      for (var y = 0.0; y <= top.last.at; y += 1) {
        final a = EdgeFeather.alphaAt(top, y);
        expect(a, lessThan(1), reason: 'translucent at $y');
        expect(a, lessThanOrEqualTo(last + 1e-9), reason: 'monotonic at $y');
        last = a;
      }
      // Text behind the middle of the header buttons stays visible.
      expect(EdgeFeather.alphaAt(top, statusBar + 34), lessThan(0.5));
    });

    test('the composer feather is clear above the composer and deepens '
        'toward the bottom edge without becoming opaque', () {
      expect(EdgeFeather.alphaAt(bottom, 0), 0);
      expect(
        EdgeFeather.alphaAt(bottom, EdgeFeather.aboveComposer),
        EdgeFeather.atComposer,
      );
      expect(EdgeFeather.alphaAt(bottom, bottom.last.at), 0.92);
      var last = -1.0;
      for (var y = 0.0; y <= bottom.last.at; y += 1) {
        final a = EdgeFeather.alphaAt(bottom, y);
        expect(a, lessThan(1));
        expect(a, greaterThanOrEqualTo(last - 1e-9));
        last = a;
      }
    });

    test('the gradient eases (no hard steps) in the theme background', () {
      final g = EdgeFeather.gradient(top, const Color(0xFFFFFFFF));
      expect(g.colors.length, greaterThan(top.length * 3));
      expect(g.colors.every((c) => c.r == 1 && c.g == 1 && c.b == 1), isTrue);
      for (var i = 1; i < g.colors.length; i++) {
        expect((g.colors[i].a - g.colors[i - 1].a).abs(), lessThan(0.2));
      }
      expect(g.stops!.first, 0);
      expect(g.stops!.last, 1);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('a long reply scrolls under the header and composer, '
        'feathered in ${b.name} theme; the bars stay tappable', (tester) async {
      await boot(tester, brightness: b, setup: seedLong);
      await openLong(tester);
      final top = feather(tester, 'top-feather');
      expect(top.top, 0);
      expect(top.height, statusBar + 56 + ThreadView.underBar);
      final bottom = feather(tester, 'bottom-feather');
      expect(bottom.bottom, screen.height);
      final pill = composerPill(tester)!;
      // Starts above the composer and covers it down to the edge.
      expect(bottom.top, lessThan(pill.top - 30));
      // Each feather is painted in the theme's background colour.
      final bg = b == Brightness.dark
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF);
      for (final key in ['top-feather', 'bottom-feather']) {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(DecoratedBox),
          ),
        );
        final g = (box.decoration as BoxDecoration).gradient! as LinearGradient;
        for (final c in g.colors) {
          expect((c.r, c.g, c.b), (bg.r, bg.g, bg.b), reason: key);
          expect(c.a, lessThan(1), reason: '$key is never opaque');
        }
        if (key == 'top-feather') {
          expect(g.colors.first.a, closeTo(EdgeFeather.topEdge, 1e-6));
          expect(g.colors.last.a, 0);
        } else {
          expect(g.colors.first.a, 0);
        }
      }

      // Scroll the reply so its text passes under the header: the drag can
      // start between the header buttons (the feather ignores pointers).
      final before = offset(tester);
      await tester.dragFrom(
        const Offset(206, statusBar + 34),
        const Offset(0, 300),
      );
      await advance(tester, 600);
      await tester.dragFrom(const Offset(206, 600), const Offset(0, -260));
      await advance(tester, 600);
      expect(offset(tester), isNot(closeTo(before, 1)));
      // Some thread text is now laid out under the header feather.
      final under = find
          .descendant(
            of: find.byType(ThreadView),
            matching: find.byType(RichText),
          )
          .evaluate()
          .map((e) => tester.getRect(find.byElementPredicate((x) => x == e)))
          .where((r) => r.bottom > 0 && r.top < top.bottom - 4);
      expect(under, isNotEmpty, reason: 'text underlaps the header');
      // Mid-reply, text also passes under (and beside) the composer.
      final pos = tester.state<ScrollableState>(threadScrollable()).position;
      pos.jumpTo(pos.maxScrollExtent - 260);
      await advance(tester, 300);
      final pillTop = composerPill(tester)!.top;
      final belowComposer = find
          .descendant(
            of: find.byType(ThreadView),
            matching: find.byType(RichText),
          )
          .evaluate()
          .map((e) => tester.getRect(find.byElementPredicate((x) => x == e)))
          .where((r) => r.bottom > pillTop && r.top < screen.height);
      expect(belowComposer, isNotEmpty, reason: 'text underlaps the composer');
      await render(
        tester,
        'reader-scroll-${b.name}',
        'Long reply scrolled: text under the header buttons and composer, '
            'feathered to ${b.name == 'dark' ? 'black' : 'white'}.',
      );

      // The header buttons and the composer still take input.
      await tester.tap(find.bySemanticsLabel('Chat options'));
      await advance(tester, 400);
      expect(find.text('Rename'), findsWidgets);
      await tester.tapAt(const Offset(10, 10));
      await advance(tester, 400);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keyboard open: the composer feather follows the composer '
      'up, and the reply still underlaps it', (tester) async {
    await boot(tester, setup: seedLong);
    await openLong(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    addTearDown(tester.view.resetViewInsets);
    await advance(tester, 400);
    final pill = composerPill(tester)!;
    expect(pill.bottom, lessThanOrEqualTo(screen.height - 420));
    final bottom = feather(tester, 'bottom-feather');
    expect(bottom.bottom, screen.height);
    // Clear 56 dp above the composer's own top (the extent includes the
    // keyboard), so the fade is visible above the pill, not under the keys.
    final composerTop = tester.getRect(find.byType(TextField)).top;
    expect(bottom.top, lessThan(composerTop - 30));
    expect(bottom.top, greaterThan(composerTop - 120));
    await render(
      tester,
      'keyboard-dark',
      'Keyboard inset 420 dp (simulated): feather sits above the raised '
          'composer.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% text: the feathers keep their geometry and the controls '
      'stay reachable', (tester) async {
    await boot(tester, textScale: 2, setup: seedLong);
    await openLong(tester);
    final top = feather(tester, 'top-feather');
    expect(top.height, statusBar + 56 + ThreadView.underBar);
    final bottom = feather(tester, 'bottom-feather');
    expect(bottom.bottom, screen.height);
    expect(find.bySemanticsLabel('Chat options').hitTestable(), findsOneWidget);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    await render(
      tester,
      'text-200-dark',
      'Text scale 2.0: header feather unchanged, composer feather follows '
          'the taller composer.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('live mode keeps its own solid header scrim and no composer '
      'feather', (tester) async {
    await boot(tester, setup: seedLong);
    await openLong(tester);
    expect(find.byKey(const ValueKey('top-feather')), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester, 900);
    expect(find.byKey(const ValueKey('top-feather')), findsNothing);
    expect(find.byKey(const ValueKey('bottom-feather')), findsNothing);
    await call.end();
    await advance(tester, 900);
  });

  group('structured replies render as real markdown', () {
    bool boldSpan(WidgetTester tester, String text) {
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        var hit = false;
        rt.text.visitChildren((s) {
          if (s is TextSpan &&
              (s.text ?? '').contains(text) &&
              (s.style?.fontWeight ?? FontWeight.w400).value >= 600) {
            hit = true;
            return false;
          }
          return true;
        });
        if (hit) return true;
      }
      return false;
    }

    Iterable<String> visibleText(WidgetTester tester) => tester
        .widgetList<RichText>(
          find.descendant(
            of: find.byType(ThreadView),
            matching: find.byType(RichText),
          ),
        )
        .map((r) => r.text.toPlainText());

    testWidgets('headings, bold labels, lists, table, code and a source '
        'pill; no literal markdown tokens', (tester) async {
      await boot(tester, setup: seedLong);
      await openLong(tester);
      final all = visibleText(tester).join('\n');
      for (final token in ['**', '## ', '| ---', '```', '[^1]']) {
        expect(all, isNot(contains(token)), reason: 'literal $token');
      }
      expect(
        find.textContaining('At a glance', findRichText: true),
        findsWidgets,
      );
      expect(boldSpan(tester, 'Strength:'), isTrue);
      expect(boldSpan(tester, 'Important:'), isTrue);
      expect(
        find.textContaining('Reduced appetite', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('take as prescribed', findRichText: true),
        findsWidgets,
      );
      await render(
        tester,
        'structured-reply-dark',
        'Synthetic structured reply (fixture), settled: headings, bold '
            'labels, lists, table, code.',
      );
    });

    testWidgets('a plain-prose reply stays plain: the renderer adds no '
        'structure of its own', (tester) async {
      const prose =
          'You have a way of committing wholeheartedly to the things that '
          'matter to you.\n\nWhat stands out is the balance in your dreams.';
      await boot(
        tester,
        setup: (b) {
          b.conversations.add(_conv('c1', 'Medicine'));
          b.stored['c1'] = [
            _stored('u0', 'user', 'Tell me something about me'),
            _stored('a0', 'assistant', prose),
          ];
        },
      );
      await openLong(tester);
      expect(boldSpan(tester, 'committing'), isFalse);
      expect(boldSpan(tester, 'balance'), isFalse);
      expect(
        visibleText(tester).where((t) => t.contains('wholeheartedly')),
        hasLength(1),
      );
    });
  });
}
