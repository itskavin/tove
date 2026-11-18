import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/background/background_replies.dart';
import 'package:tove_chat/src/notify/notify.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('banner shows title, preview and View; View opens the chat', (
    tester,
  ) async {
    final replies = BackgroundReplies();
    final notifier = ReplyNotifier(
      replies: replies,
      sink: NoopNotificationSink(),
      onScreenConversation: () => 'here',
      systemEnabled: () => true,
      appVisible: () => true,
    );
    final opened = <String>[];
    notifier.opens.listen(opened.add);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(children: [ReplyNoticeBanner(notifier: notifier)]),
        ),
      ),
    );
    expect(find.text('View'), findsNothing);

    notifier.announce(
      const ReplyNotice(
        kind: ReplyNoticeKind.reply,
        conversationId: 'c7',
        title: 'Disk space on storage',
        preview: '42 GB free',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Disk space on storage'), findsOneWidget);
    expect(find.text('42 GB free'), findsOneWidget);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(opened, ['c7']);
    expect(find.text('Disk space on storage'), findsNothing);

    notifier.announce(
      const ReplyNotice(kind: ReplyNoticeKind.failed, conversationId: 'c8'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t finish the reply'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t finish the reply'), findsNothing);

    notifier.dispose();
    replies.dispose();
  });

  testWidgets('the banner shows above a pushed page (Settings › Send a test), '
      'and touches elsewhere still reach the page', (tester) async {
    final replies = BackgroundReplies();
    final notifier = ReplyNotifier(
      replies: replies,
      sink: NoopNotificationSink(),
      onScreenConversation: () => null,
      systemEnabled: () => true,
      appVisible: () => true,
    );
    final host = ValueNotifier<ReplyNotifier?>(notifier);
    var pageTaps = 0;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (context, child) =>
            ReplyBannerLayer(notifier: host, child: child!),
        home: const Scaffold(body: Text('chat')),
      ),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => pageTaps++,
              child: const Text('Send a test notification'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send a test notification'));
    expect(pageTaps, 1, reason: 'the layer lets touches through');

    // What the events stream delivers for POST /api/events/test.
    final target = notifier.announce(
      const ReplyNotice(kind: ReplyNoticeKind.test),
    );
    expect(target, NoticeTarget.banner);
    await tester.pumpAndSettle();
    expect(find.text('Tove notifications work'), findsOneWidget);
    expect(find.text('Tove notifications work').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Tove notifications work'), findsNothing);

    host.value = null; // signed out: nothing to show
    await tester.pumpAndSettle();
    expect(find.byType(ReplyNoticeBanner), findsNothing);
    notifier.dispose();
    replies.dispose();
  });
}
