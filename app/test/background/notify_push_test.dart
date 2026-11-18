import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/background/background.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/notify/notify.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../chat/fake_http.dart';

class FakeTransport implements PushTransport {
  List<String> installed = [];
  bool hasDefault = false;
  int registers = 0, unregisters = 0;
  String? saved;
  late void Function(String) endpoint;
  late void Function(Uint8List) message;

  @override
  Future<void> initialize({
    required void Function(String endpoint) onEndpoint,
    required void Function(String reason) onFailed,
    required void Function() onUnregistered,
    required void Function(Uint8List content) onMessage,
  }) async {
    endpoint = onEndpoint;
    message = onMessage;
  }

  @override
  Future<List<String>> distributors() async => installed;
  @override
  Future<bool> useCurrentOrDefault() async => hasDefault || saved != null;
  @override
  Future<void> saveDistributor(String id) async => saved = id;
  @override
  Future<void> register() async => registers++;
  @override
  Future<void> unregister() async => unregisters++;
}

Uint8List bytes(Map<String, dynamic> j) => utf8.encode(jsonEncode(j));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('decideReplyNotice', () {
    const notice = ReplyNotice(
      kind: ReplyNoticeKind.reply,
      conversationId: 'c1',
      title: 'Disk space',
      preview: 'All fine',
    );

    test('foreground, the chat on screen: nothing', () {
      expect(
        decideReplyNotice(
          notice: notice,
          appVisible: true,
          onScreenConversation: 'c1',
          systemEnabled: true,
        ),
        NoticeTarget.none,
      );
    });
    test('foreground, another chat: in-app banner, even with the switch off',
        () {
      for (final on in [true, false]) {
        expect(
          decideReplyNotice(
            notice: notice,
            appVisible: true,
            onScreenConversation: 'c2',
            systemEnabled: on,
          ),
          NoticeTarget.banner,
        );
      }
    });
    test('background: system notification unless off or already pushed', () {
      NoticeTarget d({bool on = true, bool pushed = false}) =>
          decideReplyNotice(
            notice: notice,
            appVisible: false,
            onScreenConversation: 'c1',
            systemEnabled: on,
            alreadyNotified: pushed,
          );
      expect(d(), NoticeTarget.system);
      expect(d(on: false), NoticeTarget.none);
      expect(d(pushed: true), NoticeTarget.none);
    });
    test('no notice (a stopped reply): nothing', () {
      expect(
        decideReplyNotice(
          notice: null,
          appVisible: false,
          onScreenConversation: null,
          systemEnabled: true,
        ),
        NoticeTarget.none,
      );
    });
    test('generic text without previews; failures say so', () {
      const bare = ReplyNotice(kind: ReplyNoticeKind.reply);
      expect(bare.body, 'Reply ready');
      expect(bare.heading, isNotEmpty);
      const failed = ReplyNotice(kind: ReplyNoticeKind.failed, title: 'T');
      expect(failed.body, 'Couldn’t finish the reply');
      expect(
        const ReplyNotice(kind: ReplyNoticeKind.reply, conversationId: 'c1')
            .notificationId,
        notice.notificationId,
        reason: 'one notification per chat',
      );
    });
  });

  group('ReplyNotifier', () {
    late FakeHttp http;
    late ChatApi api;
    late BackgroundReplies replies;
    late NoopNotificationSink sink;
    late ReplyNotifier notifier;
    String? onScreen;
    var visible = true;
    var enabled = true;

    setUp(() {
      http = FakeHttp();
      api = fakeApi(http);
      replies = BackgroundReplies();
      sink = NoopNotificationSink();
      onScreen = 'here';
      visible = true;
      enabled = true;
      notifier = ReplyNotifier(
        replies: replies,
        sink: sink,
        onScreenConversation: () => onScreen,
        systemEnabled: () => enabled,
        appVisible: () => visible,
      );
    });
    tearDown(() {
      notifier.dispose();
      replies.dispose();
    });

    Future<void> finishReply(String conv, String msg, {String end = 'done'}) async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      replies.send(api, conversationId: conv, text: 'hi', title: 'Chat $conv');
      await settle();
      body.meta(conv: conv, msg: msg, title: 'Chat $conv');
      body.delta('**Answer** for $conv');
      if (end == 'done') {
        body.done(conv: conv, msg: msg, title: 'Chat $conv');
      } else {
        body.event('stopped', {'conversation_id': conv, 'message_id': msg});
      }
      await settle(10);
    }

    test('a reply finishing in another chat raises a banner with View', () async {
      final opened = <String>[];
      notifier.opens.listen(opened.add);
      await finishReply('elsewhere', 'a1');
      final n = notifier.current.value!;
      expect(n.heading, 'Chat elsewhere');
      expect(n.body, 'Answer for elsewhere', reason: 'markdown stripped');
      expect(sink.shown, isEmpty);
      notifier.view(n);
      await settle();
      expect(opened, ['elsewhere']);
      expect(notifier.current.value, isNull);
    });

    test('in the chat on screen: no banner', () async {
      await finishReply('here', 'a1');
      expect(notifier.current.value, isNull);
      expect(sink.shown, isEmpty);
    });

    test('in the background: a system notification; off: none', () async {
      visible = false;
      await finishReply('here', 'a1');
      expect(sink.shown.single.conversationId, 'here');
      enabled = false;
      await finishReply('here', 'a2');
      expect(sink.shown.length, 1);
    });

    test('a stopped reply is never announced', () async {
      visible = false;
      await finishReply('x', 'a1', end: 'stopped');
      expect(sink.shown, isEmpty);
    });

    test('a pushed reply is not announced again when it resumes', () async {
      visible = false;
      expect(
        notifier.announce(
          const ReplyNotice(
            kind: ReplyNoticeKind.reply,
            conversationId: 'x',
            messageId: 'a1',
          ),
        ),
        NoticeTarget.system,
      );
      visible = true;
      await finishReply('x', 'a1');
      expect(notifier.current.value, isNull);
    });

    test('notification taps arrive on opens', () async {
      final opened = <String>[];
      notifier.opens.listen(opened.add);
      sink.tap('c9');
      await settle();
      expect(opened, ['c9']);
    });
  });

  group('PushPayload', () {
    test('parses the bridge body', () {
      final p = PushPayload.parse(bytes({
        'type': 'chat.reply',
        'conversation_id': 'c1',
        'message_id': 'm1',
        'title': 'Disk space on storage',
        'preview': 'Plain text…',
        'status': 'done',
        'sent': 1794691021626,
      }))!;
      expect(p.type, 'chat.reply');
      expect(p.sent, DateTime.fromMillisecondsSinceEpoch(1794691021626));
      final n = p.toNotice()!;
      expect(n.kind, ReplyNoticeKind.reply);
      expect(n.conversationId, 'c1');
      expect(n.heading, 'Disk space on storage');
    });

    test('previews off, failures, tasks, tests, stopped and junk', () {
      final bare = PushPayload.parse(bytes({
        'type': 'chat.reply', 'conversation_id': 'c1', 'message_id': 'm1',
        'title': null, 'preview': null, 'status': 'done',
      }))!.toNotice()!;
      expect(bare.body, 'Reply ready');
      expect(
        PushPayload.parse(bytes({'type': 'chat.reply', 'status': 'failed'}))!
            .toNotice()!
            .kind,
        ReplyNoticeKind.failed,
      );
      final task = PushPayload.parse(bytes({
        'type': 'live.task', 'conversation_id': null, 'message_id': null,
        'preview': 'Backup done', 'status': 'done',
      }))!.toNotice()!;
      expect(task.kind, ReplyNoticeKind.task);
      expect(task.conversationId, isNull);
      expect(PushPayload.parse(bytes({'type': 'test'}))!.toNotice()!.kind,
          ReplyNoticeKind.test);
      expect(
        PushPayload.parse(bytes({'type': 'chat.reply', 'status': 'stopped'}))!
            .toNotice(),
        isNull,
      );
      expect(PushPayload.parse(utf8.encode('not json')), isNull);
      expect(PushPayload.parse(bytes({'no': 'type'})), isNull);
      expect(PushPayload.parse(bytes({'type': 'future.kind'}))!.toNotice(),
          isNull);
    });

    test('handlePushMessage shows it, marks the reply, respects the switch',
        () async {
      final sink = NoopNotificationSink();
      final store = MemoryReplyStore([
        InFlightReply(
          server: 's', messageId: 'm1', conversationId: 'c1',
          started: DateTime.now(),
        ),
      ]);
      final body = bytes({
        'type': 'chat.reply', 'conversation_id': 'c1', 'message_id': 'm1',
        'status': 'done',
      });
      await handlePushMessage(body, sink: sink, replyStore: store,
          enabled: () async => false);
      expect(sink.shown, isEmpty);
      await handlePushMessage(body, sink: sink, replyStore: store,
          enabled: () async => true);
      expect(sink.shown.single.messageId, 'm1');
      expect(store.items.single.notified, isTrue);
    });
  });

  group('PushRegistrar', () {
    late FakeHttp http;
    late ChatApi api;
    late BackgroundReplies replies;
    late ReplyNotificationPrefs prefs;
    late FakeTransport transport;
    late PushRegistrar push;
    final notices = <ReplyNotice>[];

    setUp(() async {
      http = FakeHttp();
      api = fakeApi(http);
      http.on('GET /api/capabilities', (_) => jsonResponse(resumableCapabilities));
      await api.capabilities();
      replies = BackgroundReplies();
      prefs = ReplyNotificationPrefs();
      await prefs.load();
      transport = FakeTransport();
      notices.clear();
      push = PushRegistrar(
        replies: replies,
        prefs: prefs,
        onNotice: notices.add,
        transport: transport,
        appVersion: '1.0.0',
      );
    });
    tearDown(() {
      push.dispose();
      replies.dispose();
    });

    test('registers the endpoint with a stable device id', () async {
      transport.hasDefault = true;
      http.on('POST /api/push/register',
          (_) => jsonResponse({'ok': true, 'device_id': 'x', 'previews': false}));
      await push.start(api);
      expect(push.state, PushState.registering);
      expect(transport.registers, 1);
      transport.endpoint('https://ntfy.example.org/upAbC?up=1');
      await settle();
      final body = http.last('POST /api/push/register').body;
      expect(body['endpoint'], 'https://ntfy.example.org/upAbC?up=1');
      expect(body['app_version'], '1.0.0');
      final id = body['device_id'] as String;
      expect(RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id), isTrue);
      expect(await push.deviceId(), id);
      expect(push.state, PushState.active);
      expect(push.previews, isFalse);
      expect(replies.pushActive, isTrue);

      transport.message(bytes({'type': 'chat.reply', 'conversation_id': 'c',
          'message_id': 'm', 'status': 'done'}));
      expect(notices.single.conversationId, 'c');
    });

    test('no distributor installed: needsDistributor (WorkManager fallback)',
        () async {
      await push.start(api);
      expect(push.state, PushState.needsDistributor);
      expect(replies.pushActive, isFalse);
      transport.installed = ['io.heckel.ntfy', 'org.example.up'];
      await push.start(api);
      expect(push.state, PushState.choosing);
      await push.chooseDistributor('io.heckel.ntfy');
      expect(transport.saved, 'io.heckel.ntfy');
      expect(transport.registers, 1);
    });

    test('turning notifications off and signing out unregister', () async {
      transport.hasDefault = true;
      http.on('POST /api/push/register', (_) => jsonResponse({'ok': true}));
      http.on('DELETE /api/push/register/${await push.deviceId()}',
          (_) => jsonResponse({'ok': true, 'removed': true}));
      await push.start(api);
      transport.endpoint('https://ntfy.example.org/up1');
      await settle();
      await prefs.setEnabled(false);
      await settle();
      expect(http.count('DELETE /api/push/register/${await push.deviceId()}'), 1);
      expect(transport.unregisters, 1);
      expect(push.state, PushState.off);
      expect(replies.pushActive, isFalse);
      await push.signOut();
      expect(transport.unregisters, 2);
    });

    test('a bridge without push leaves it off', () async {
      final old = fakeApi(http);
      http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
      await old.capabilities();
      await push.start(old);
      expect(push.state, PushState.off);
      expect(transport.registers, 0);
    });

    test('too many devices is reported', () async {
      transport.hasDefault = true;
      http.on('POST /api/push/register',
          (_) => errorResponse(409, 'too_many_devices'));
      await push.start(api);
      transport.endpoint('https://ntfy.example.org/up1');
      await settle();
      expect(push.state, PushState.failed);
      expect(push.problem, contains('10 devices'));
    });
  });

  group('runReplyCheck (WorkManager fallback)', () {
    test('notifies finished replies, keeps running ones, drops old ones',
        () async {
      final http = FakeHttp();
      final api = fakeApi(http);
      final server = api.baseUrl.toString();
      final now = DateTime.now();
      final store = MemoryReplyStore([
        InFlightReply(server: server, messageId: 'a1', conversationId: 'c1',
            started: now, title: 'Done chat'),
        InFlightReply(server: server, messageId: 'a2', conversationId: 'c2',
            started: now),
        InFlightReply(server: server, messageId: 'a3', conversationId: 'c3',
            started: now.subtract(const Duration(days: 2))),
        InFlightReply(server: 'other', messageId: 'z', conversationId: 'z',
            started: now),
      ]);
      http.on('GET /api/conversations/c1', (_) => jsonResponse({
            'conversation': conversationJson('c1'),
            'messages': [messageJson('a1', conv: 'c1', role: 'assistant',
                text: 'All   done')],
            'has_more': false,
          }));
      http.on('GET /api/conversations/c2', (_) => jsonResponse({
            'conversation': conversationJson('c2'),
            'messages': [messageJson('a2', conv: 'c2', role: 'assistant',
                text: 'Wor', status: 'streaming')],
            'has_more': false,
          }));
      final sink = NoopNotificationSink();
      final left = await runReplyCheck(
        api: api, store: store, sink: sink, enabled: () async => true);
      expect(left, 1);
      expect(sink.shown.single.heading, 'Done chat');
      expect(sink.shown.single.body, 'All done');
      expect(store.items.map((e) => e.messageId), ['a2', 'z']);
      expect(http.count('GET /api/conversations/c3'), 0);
    });
  });
}
