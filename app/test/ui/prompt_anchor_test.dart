import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/thread/follow_scroll.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:tove_chat/src/ui/thread/thread_view.dart';

import '../chat/fake_http.dart';
import 'test_harness.dart';

/// A sent message comes up under the app bar with its reply below it
/// (ChatGPT-like), the stream does not drag the view, and opened chats are
/// not anchored.
void main() {
  const topInset = 80.0;
  const restTop = topInset + ThreadView.underBar;
  const viewH = 915.0;

  late FakeHttp http;
  late ConversationsController convs;
  late ChatController chat;
  late FollowScrollController scroll;
  late List<SseBody> bodies;
  var ids = 0;

  setUp(() {
    ids = 0;
    http = FakeHttp();
    bodies = [];
    final api = fakeApi(http);
    convs = ConversationsController(api: api);
    chat = ChatController(
      api: api,
      conversations: convs,
      defaultEffort: () => ChatEffort.medium,
      newClientId: () => 'c-${++ids}',
      titleRefreshDelay: const Duration(milliseconds: 20),
    );
    scroll = FollowScrollController();
    http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({'conversations': [], 'next_cursor': null}),
    );
    http.on('POST /api/chat', (_) {
      final b = SseBody();
      bodies.add(b);
      return b.response();
    });
  });

  tearDown(() {
    chat.dispose();
    convs.dispose();
    scroll.dispose();
  });

  Widget thread({double bottomInset = 100, bool reduce = false}) => themed(
    reduce: reduce,
    Scaffold(
      body: ThreadView(
        chat: chat,
        scroll: scroll,
        topInset: topInset,
        bottomInset: bottomInset,
        onSuggestion: (_) {},
      ),
    ),
  );

  Future<void> frames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    double bottomInset = 100,
    bool reduce = false,
    double textScale = 1,
  }) async {
    phoneSize(tester, size: const Size(412, viewH));
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await chat.init();
    await tester.pumpWidget(thread(bottomInset: bottomInset, reduce: reduce));
    await frames(tester, 2);
  }

  Rect bubble(WidgetTester tester, String text) => tester.getRect(
    find.ancestor(of: find.text(text), matching: find.byType(UserBubble)),
  );

  /// Opens a stored chat of [pairs] exchanges.
  Future<void> openStored(WidgetTester tester, int pairs) async {
    http.on(
      'GET /api/conversations/conv1',
      (_) => jsonResponse({
        'conversation': conversationJson('conv1', title: 'A stored chat'),
        'messages': [
          for (var i = 0; i < pairs; i++) ...[
            messageJson('u$i', text: 'Question $i'),
            messageJson(
              'a$i',
              role: 'assistant',
              text: 'Answer $i.\n\nIt has two paragraphs of text.',
            ),
          ],
        ],
        'has_more': false,
      }),
    );
    await chat.load('conv1');
    await frames(tester);
  }

  Future<void> send(WidgetTester tester, String text) async {
    // ignore: discarded_futures
    chat.send(text);
    await frames(tester, 10);
  }

  /// Streams [lines] of reply text in chunks of one line.
  Future<void> stream(WidgetTester tester, SseBody b, int lines) async {
    for (var i = 0; i < lines; i++) {
      b.delta('Line $i of the reply, long enough to read.\n\n');
      await frames(tester, 2);
    }
  }

  Future<void> finish(WidgetTester tester, SseBody b, String conv) async {
    b.done(conv: conv, msg: 'a-${bodies.length}');
    await b.close();
    await frames(tester, 10);
  }

  double maxExtent() => scroll.position.maxScrollExtent;
  double pixels() => scroll.position.pixels;

  testWidgets('new chat: the first prompt sits under the app bar, the short '
      'reply below it, through the stream', (tester) async {
    await mount(tester);
    await send(tester, 'How full are the disks?');
    expect(bubble(tester, 'How full are the disks?').top, closeTo(restTop, 1));
    final b = bodies.single;
    b.meta(conv: 'new1', msg: 'a-1', user: 'u-1', client: 'c-1', created: true);
    b.delta('The disk is 40% full.');
    await frames(tester);
    final top = bubble(tester, 'How full are the disks?');
    expect(top.top, closeTo(restTop, 1), reason: 'a new chat id is the same');
    final reply = tester.getRect(find.textContaining('40% full').first);
    expect(reply.top, greaterThan(top.bottom), reason: 'the reply is below');
    expect(reply.bottom, lessThan(viewH - 100));
    await finish(tester, b, 'new1');
    expect(bubble(tester, 'How full are the disks?').top, closeTo(restTop, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long chat: a multi-line prompt rises to the top; a long '
      'reply streams below without moving it; jump follows again', (
    tester,
  ) async {
    await mount(tester);
    await openStored(tester, 12);
    expect(pixels(), maxExtent(), reason: 'opened at the newest message');
    const prompt = 'First line of the prompt\nsecond line\nand a third line';
    await send(tester, prompt);
    expect(bubble(tester, prompt).top, closeTo(restTop, 1));
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    await stream(tester, b, 40);
    expect(
      bubble(tester, prompt).top,
      closeTo(restTop, 1),
      reason: 'the stream does not scroll the view',
    );
    expect(maxExtent() - pixels(), greaterThan(viewH));
    final jump = find.bySemanticsLabel('Scroll to latest');
    expect(jump, findsOneWidget);
    await tester.tap(jump);
    await frames(tester, 12);
    expect(pixels(), closeTo(maxExtent(), 1));
    await stream(tester, b, 5);
    expect(
      pixels(),
      closeTo(maxExtent(), 1),
      reason: 'after the jump, the stream is followed',
    );
    await finish(tester, b, 'conv1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reader who scrolls away during the stream is not pulled '
      'back', (tester) async {
    await mount(tester);
    await openStored(tester, 8);
    await send(tester, 'Explain the backups');
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    await stream(tester, b, 6);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await frames(tester, 12);
    final reading = pixels();
    final prompt = bubble(tester, 'Explain the backups').top;
    expect(prompt, greaterThan(restTop + 200), reason: 'the user moved it');
    await stream(tester, b, 20);
    expect(pixels(), reading);
    expect(bubble(tester, 'Explain the backups').top, prompt);
    // Scrolling down onto the newest message leaves it where the user put
    // it too.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
    await frames(tester, 12);
    final again = pixels();
    await stream(tester, b, 4);
    expect(pixels(), again);
    await finish(tester, b, 'conv1');
  });

  testWidgets('the keyboard opening and closing leaves the prompt on top', (
    tester,
  ) async {
    await mount(tester, bottomInset: 420);
    await openStored(tester, 6);
    await send(tester, 'Is everything healthy?');
    expect(bubble(tester, 'Is everything healthy?').top, closeTo(restTop, 1));
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    b.delta('Yes, all three machines report in.');
    await frames(tester);
    // Keyboard hides: the thread's bottom inset shrinks.
    await tester.pumpWidget(thread(bottomInset: 100));
    await frames(tester);
    expect(bubble(tester, 'Is everything healthy?').top, closeTo(restTop, 1));
    final reply = tester.getRect(find.textContaining('report in').first);
    expect(reply.bottom, lessThan(viewH - 100));
    // And shows again.
    await tester.pumpWidget(thread(bottomInset: 420));
    await frames(tester);
    expect(bubble(tester, 'Is everything healthy?').top, closeTo(restTop, 1));
    await finish(tester, b, 'conv1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second prompt takes the top; stop and retry keep it there', (
    tester,
  ) async {
    await mount(tester);
    await send(tester, 'First question');
    final first = bodies.single;
    first.meta(conv: 'n1', msg: 'a-1', user: 'u-1', client: 'c-1');
    await stream(tester, first, 3);
    await finish(tester, first, 'n1');
    await send(tester, 'Second question');
    expect(bubble(tester, 'Second question').top, closeTo(restTop, 1));
    expect(
      find.text('First question').hitTestable(),
      findsNothing,
      reason: 'the earlier turn is above the app bar',
    );
    final second = bodies.last;
    second.meta(conv: 'n1', msg: 'a-2', user: 'u-2', client: 'c-2');
    await stream(tester, second, 2);
    chat.stop();
    await frames(tester, 10);
    expect(bubble(tester, 'Second question').top, closeTo(restTop, 1));
    // ignore: discarded_futures
    chat.retry(chat.messages.last);
    await frames(tester, 10);
    final again = bodies.last;
    expect(again, isNot(same(second)));
    again.meta(conv: 'n1', msg: 'a-3', user: 'u-2', client: 'c-2');
    await stream(tester, again, 3);
    expect(bubble(tester, 'Second question').top, closeTo(restTop, 1));
    await finish(tester, again, 'n1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening a chat shows its newest messages with no spacer', (
    tester,
  ) async {
    await mount(tester);
    await openStored(tester, 1);
    await send(tester, 'Short one');
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    b.delta('Ok.');
    await finish(tester, b, 'conv1');
    expect(bubble(tester, 'Short one').top, closeTo(restTop, 1));
    // Reopen: a short chat fits the screen and does not scroll at all.
    await openStored(tester, 1);
    expect(maxExtent(), 0, reason: 'no artificial room below a short chat');
    expect(bubble(tester, 'Question 0').top, closeTo(restTop, 1));
    // A long stored chat opens at its end, the last reply just above the
    // composer, not under the app bar.
    await openStored(tester, 12);
    expect(pixels(), closeTo(maxExtent(), 1));
    final last = tester.getRect(find.textContaining('Answer 11').first);
    expect(last.top, greaterThan(viewH / 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: the prompt is placed without animating', (
    tester,
  ) async {
    await mount(tester, reduce: true);
    await openStored(tester, 8);
    // ignore: discarded_futures
    chat.send('Summarise today’s alerts');
    await tester.pump();
    await tester.pump();
    expect(
      bubble(tester, 'Summarise today’s alerts').top,
      closeTo(restTop, 1),
      reason: 'in place on the first frame after layout',
    );
    await frames(tester);
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    await finish(tester, b, 'conv1');
  });

  testWidgets('200% text: a long wrapped prompt still starts at the top', (
    tester,
  ) async {
    await mount(tester, textScale: 2);
    await openStored(tester, 4);
    const prompt =
        'Please check every disk on every machine and tell me which one '
        'is closest to full';
    await send(tester, prompt);
    expect(bubble(tester, prompt).top, closeTo(restTop, 1));
    final b = bodies.single;
    b.meta(conv: 'conv1', msg: 'a-1', user: 'u-1', client: 'c-1');
    await stream(tester, b, 3);
    expect(bubble(tester, prompt).top, closeTo(restTop, 1));
    await finish(tester, b, 'conv1');
    expect(tester.takeException(), isNull);
  });
}
