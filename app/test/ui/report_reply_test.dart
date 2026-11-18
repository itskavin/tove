import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/thread/message_actions.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:tove_chat/src/ui/thread/report_sheet.dart';

import '../chat/fake_http.dart';
import 'test_harness.dart';

ChatMessage _reply({String id = 'a1'}) => ChatMessage(
  id: id,
  conversationId: 'c1',
  role: MessageRole.assistant,
  text: 'Some answer.',
  status: MessageStatus.done,
  created: DateTime(2026, 11, 15),
);

/// Report reply: More › Report reply, a
/// reason and note sheet, POST /api/report to the user's own bridge, and
/// hiding the reply on this device.
void main() {
  late FakeHttp http;
  late ChatApi api;
  late HiddenReplies hidden;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    http = FakeHttp();
    api = fakeApi(http);
    hidden = HiddenReplies();
    HiddenReplies.instance = hidden;
  });
  tearDown(() => HiddenReplies.instance = null);

  group('submitReport', () {
    test('sends reason, note and hidden; hides locally', () async {
      http.on(
        'POST /api/report',
        (_) => jsonResponse({'ok': true, 'id': 'rep_1'}),
      );
      final r = await submitReport(
        api,
        messageId: 'a1',
        conversationId: 'c1',
        report: const ReplyReport(
          reason: ReportReason.harmful,
          note: '  unsafe  ',
        ),
        hidden: hidden,
      );
      expect(r, (sent: true, hidden: true));
      final req = http.last('POST /api/report');
      expect(req.body, {
        'message_id': 'a1',
        'conversation_id': 'c1',
        'reason': 'harmful',
        'note': 'unsafe',
        'hidden': true,
      });
      expect(req.headers['Authorization'], 'Bearer $chatTestKey');
      expect(hidden.isHidden('a1'), isTrue);
      // Persisted: a new store reads it back.
      final again = HiddenReplies();
      await again.load();
      expect(again.isHidden('a1'), isTrue);
      await again.unhide('a1');
      final third = HiddenReplies();
      await third.load();
      expect(third.isHidden('a1'), isFalse);
    });

    test('an old bridge (404) still hides; no hide means not hidden', () async {
      final r = await submitReport(
        api,
        messageId: 'a2',
        report: const ReplyReport(reason: ReportReason.wrong),
        hidden: hidden,
      );
      expect(r, (sent: false, hidden: true));
      expect(hidden.isHidden('a2'), isTrue);
      http.on('POST /api/report', (_) => jsonResponse({'ok': true}));
      final r2 = await submitReport(
        api,
        messageId: 'a3',
        report: const ReplyReport(reason: ReportReason.other, hide: false),
        hidden: hidden,
      );
      expect(r2, (sent: true, hidden: false));
      expect(hidden.isHidden('a3'), isFalse);
      expect(http.last('POST /api/report').body.containsKey('note'), isFalse);
    });
  });

  group('menu', () {
    Future<void> pump(WidgetTester tester, {VoidCallback? onReport}) async {
      phoneSize(tester);
      await tester.pumpWidget(
        themed(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: AssistantMessage(
                message: _reply(),
                onRetry: null,
                onDelete: () {},
                onReport: onReport,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
    }

    testWidgets('More › Report reply calls onReport', (tester) async {
      var reported = 0;
      await pump(tester, onReport: () => reported++);
      expect(find.text('Report reply'), findsOneWidget);
      await tester.tap(find.text('Report reply'));
      await tester.pumpAndSettle();
      expect(reported, 1);
    });

    testWidgets('no onReport: no item', (tester) async {
      await pump(tester);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Report reply'), findsNothing);
    });
  });

  testWidgets('the sheet: reason required, note, hide, then sent', (
    tester,
  ) async {
    phoneSize(tester);
    http.on('POST /api/report', (_) => jsonResponse({'ok': true, 'id': 'r'}));
    final toasts = <String>[];
    late BuildContext ctx;
    await tester.pumpWidget(
      themed(
        MessageActions(
          share: (_) async {},
          notify: toasts.add,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    final done = reportReply(ctx, api, _reply(id: 'a9'), hidden: hidden);
    await tester.pumpAndSettle();
    expect(find.text('Report reply'), findsOneWidget);
    for (final r in ReportReason.values) {
      expect(find.text(r.label), findsOneWidget);
    }
    final send = find.byKey(const ValueKey('report-send'));
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(find.text(ReportReason.offensive.label));
    await tester.pump();
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await tester.enterText(
      find.byKey(const ValueKey('report-note')),
      'Rude reply',
    );
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    await done;
    expect(http.last('POST /api/report').body, {
      'message_id': 'a9',
      'conversation_id': 'c1',
      'reason': 'offensive',
      'note': 'Rude reply',
      'hidden': true,
    });
    expect(hidden.isHidden('a9'), isTrue);
    expect(toasts, ['Reported and hidden']);
  });

  testWidgets('a hidden reply shows a notice with Show', (tester) async {
    var shown = 0;
    await tester.pumpWidget(
      themed(Scaffold(body: HiddenReplyNotice(onShow: () => shown++))),
    );
    expect(find.text('You reported and hid this reply.'), findsOneWidget);
    await tester.tap(find.text('Show'));
    expect(shown, 1);
  });
}
