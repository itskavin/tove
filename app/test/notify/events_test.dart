import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tove_chat/src/background/background.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/notify/notify.dart';

import '../chat/fake_http.dart';

/// The bridge's notification stream (API.md "Events"): parsing, which events
/// announce what, the app's own foreground stream, the Android service
/// bridge and the 15-minute background check.
void main() {
  late FakeHttp http;
  late ChatApi api;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    http = FakeHttp();
    api = fakeApi(http);
  });

  Map<String, dynamic> data(
    String conv, {
    String? msg,
    String status = 'done',
    bool watched = false,
    String? preview = 'Disk is fine',
  }) => {
    'conversation_id': conv,
    'message_id': msg ?? 'm-$conv',
    'status': status,
    'title': 'Disk check',
    'preview': preview,
    'watched': watched,
    'created': 1794691021626,
  };

  group('events model', () {
    test('parses SSE, forwarded and polled events', () {
      final e = BridgeEvent.fromSse(
        SseEvent('task.done', jsonEncode(data('c1')), id: '7'),
      )!;
      expect(
        (e.type, e.id, e.conversationId, e.messageId, e.status, e.title),
        ('task.done', 7, 'c1', 'm-c1', 'done', 'Disk check'),
      );
      final hello = BridgeEvent.fromSse(
        SseEvent(
          'hello',
          '{"version":1,"last_id":12,"heartbeat_s":80,"reset":"gap"}',
        ),
      )!;
      expect(
        (hello.isHello, hello.lastId, hello.heartbeat, hello.reset),
        (true, 12, 80, 'gap'),
      );
      final fwd = BridgeEvent.fromForwarded(
        jsonEncode({
          'type': 'notify',
          'id': 3,
          'data': {'conversation_id': 'tove', 'kind': 'alert'},
        }),
      )!;
      expect((fwd.type, fwd.id, fwd.kind), ('notify', 3, 'alert'));
      expect(BridgeEvent.fromForwarded('nope'), isNull);
      final page = EventsPage.fromJson({
        'events': [
          {'id': 4, 'type': 'reply.done', 'data': data('c2')},
          {'bad': true},
        ],
        'last_id': 4,
        'reset': null,
        'more': false,
      });
      expect((page.events.single.id, page.lastId, page.more), (4, 4, false));
    });

    test('what each event announces', () {
      ReplyNoticeKind? kind(String type, Map<String, dynamic> d) =>
          noticeForEvent(BridgeEvent.fromJson(type, 1, d))?.kind;
      expect(kind('reply.done', data('c')), ReplyNoticeKind.reply);
      expect(
        kind('reply.done', data('c', status: 'failed')),
        ReplyNoticeKind.failed,
      );
      expect(kind('reply.done', data('c', status: 'stopped')), isNull);
      expect(kind('reply.done', data('c', watched: true)), isNull);
      expect(kind('task.done', data('c')), ReplyNoticeKind.task);
      expect(
        kind('task.done', data('c', status: 'failed')),
        ReplyNoticeKind.taskFailed,
      );
      expect(kind('task.done', data('c', watched: true)), isNull);
      expect(kind('task.started', data('c')), isNull);
      expect(kind('notify', data('c')), ReplyNoticeKind.reply);
      expect(kind('test', const {}), ReplyNoticeKind.test);
      final failed = noticeForEvent(
        BridgeEvent.fromJson(
          'task.done',
          1,
          data('c', status: 'failed', preview: null),
        ),
      )!;
      expect(failed.body, contains('didn’t finish'));
    });
  });

  group('the app’s own stream (foreground only)', () {
    late SseBody body;
    late List<ReplyNotice> notices;
    late List<BridgeEvent> seen;
    late EventsHub hub;
    var own = true;

    setUp(() {
      body = SseBody();
      notices = [];
      seen = [];
      own = true;
      http.on('GET /api/events', (_) => body.response());
      hub = EventsHub(
        api: api,
        announce: (n) {
          if (n != null) notices.add(n);
          return NoticeTarget.banner;
        },
        onEvent: seen.add,
        useOwnStream: () => own,
        keepWhenHidden: false,
        heartbeat: 80,
        deviceId: () => 'phone-1',
      );
    });
    tearDown(() => hub.dispose());

    test(
      'opens while visible, handles each event once, closes in the background',
      () async {
        hub.setSupported(true);
        await settle();
        expect(http.count('GET /api/events'), 0, reason: 'not visible yet');
        hub.setForeground(true);
        await settle();
        final req = http.last('GET /api/events');
        expect(req.query, {'heartbeat': '80', 'device_id': 'phone-1'});
        expect(
          req.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('last-event-id')),
        );
        body.event('hello', {
          'version': 1,
          'last_id': 9,
          'heartbeat_s': 80,
          'reset': null,
        });
        body.idEvent(10, 'task.started', data('c1'));
        body.idEvent(11, 'task.done', data('c1'));
        body.idEvent(11, 'task.done', data('c1')); // a replay: once
        body.idEvent(12, 'reply.done', data('c2', watched: true));
        await settle();
        expect(seen.map((e) => e.id), [10, 11, 12]);
        expect(notices.map((n) => n.kind), [ReplyNoticeKind.task]);
        expect(hub.lastId, 12);
        // The Android service forwards events with the same ids: no repeats.
        hub.handle(BridgeEvent.fromJson('task.done', 11, data('c1')));
        expect(notices, hasLength(1));
        hub.setForeground(false);
        await settle();
        expect(body.cancelled, isTrue);
        expect(hub.connection, isNull);
      },
    );

    test('reconnects with Last-Event-ID after a drop; stops on 401', () async {
      hub
        ..setSupported(true)
        ..setForeground(true);
      await settle();
      body.event('hello', {'version': 1, 'last_id': 3});
      body.idEvent(4, 'notify', data('tove'));
      await settle();
      final second = SseBody();
      http.on('GET /api/events', (_) => second.response());
      await body.close();
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      await settle();
      final again = http.last('GET /api/events');
      expect(again.headers['Last-Event-ID'], '4');
      http.on('GET /api/events', (_) => errorResponse(401, 'unauthorized'));
      await second.close();
      await Future<void>.delayed(const Duration(milliseconds: 5200));
      await settle();
      final n = http.count('GET /api/events');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        http.count('GET /api/events'),
        n,
        reason: 'a bad key is not retried',
      );
    });

    test('no second connection while the Android service holds one', () async {
      own = false;
      hub
        ..setSupported(true)
        ..setForeground(true);
      await settle();
      expect(http.count('GET /api/events'), 0);
      own = true;
      hub.refresh();
      await settle();
      expect(http.count('GET /api/events'), 1);
    });
  });

  group('instant notifications (Android service)', () {
    late _FakePlatform platform;
    late InstantNotifications instant;

    setUp(() async {
      platform = _FakePlatform();
      instant = InstantNotifications(platform: platform, supported: true);
      await instant.load();
    });
    tearDown(() => instant.dispose());

    test('on by default; runs only when the bridge offers events and notifications are on', () async {
      expect(instant.enabled, isTrue);
      await instant.configure(
        bridgeOffers: true,
        url: 'https://bridge.test',
        accessKey: 'k' * 30,
        systemEnabled: true,
        deviceId: 'phone-1',
      );
      final args = platform.calls.last.$2 as Map;
      expect(
        (
          args['enabled'],
          args['url'],
          args['key'],
          args['deviceId'],
          args['heartbeat'],
        ),
        (true, 'https://bridge.test', 'k' * 30, 'phone-1', 80),
      );
      expect(instant.status.state, InstantState.connecting);
      await instant.configure(
        bridgeOffers: true,
        url: 'https://bridge.test',
        accessKey: 'k' * 30,
        systemEnabled: false,
      );
      expect((platform.calls.last.$2 as Map)['enabled'], isFalse);
      expect(
        (platform.calls.last.$2 as Map)['key'],
        '',
        reason: 'the key only goes over when needed',
      );
      await instant.configure(
        bridgeOffers: false,
        url: 'https://bridge.test',
        accessKey: 'k' * 30,
        systemEnabled: true,
      );
      expect((platform.calls.last.$2 as Map)['enabled'], isFalse);
    });

    test('the switch reconfigures, and is remembered', () async {
      await instant.configure(
        bridgeOffers: true,
        url: 'https://bridge.test',
        accessKey: 'k' * 30,
        systemEnabled: true,
      );
      expect((platform.calls.last.$2 as Map)['enabled'], isTrue);
      await instant.setEnabled(false);
      expect((platform.calls.last.$2 as Map)['enabled'], isFalse);
      expect(
        await SharedPreferencesAsync().getBool(InstantNotifications.enabledKey),
        isFalse,
      );
      final again = InstantNotifications(
        platform: _FakePlatform(),
        supported: true,
      );
      await again.load();
      expect(again.enabled, isFalse);
      again.dispose();
    });

    test('an unset preference (the opt-in builds never wrote one) is on; '
        'an explicit choice is kept', () async {
      expect(
        await SharedPreferencesAsync().getBool(InstantNotifications.enabledKey),
        isNull,
      );
      expect(instant.enabled, isTrue);
      await SharedPreferencesAsync().setBool(
        InstantNotifications.enabledKey,
        true,
      );
      final on = InstantNotifications(platform: _FakePlatform(), supported: true);
      await on.load();
      expect(on.enabled, isTrue);
      on.dispose();
    });

    test('forwarded events, notification taps and the status map', () async {
      final got = <BridgeEvent>[];
      final opens = <String>[];
      instant.events.listen(got.add);
      instant.opens.listen(opens.add);
      await platform.send(
        'event',
        jsonEncode({'type': 'reply.done', 'id': 5, 'data': data('c9')}),
      );
      await platform.send('open', 'c9');
      await settle();
      expect(got.single.conversationId, 'c9');
      expect(opens, ['c9']);
      platform.status = {
        'enabled': true,
        'status': 'connected',
        'connectedAt': 1794691021626,
        'heartbeatAt': 1794691101626,
        'lastId': 5,
        'batteryExempt': false,
        'notificationsAllowed': true,
      };
      final s = await instant.refreshStatus();
      expect(
        (s.state, s.lastId, s.batteryExempt, s.running),
        (InstantState.connected, 5, false, true),
      );
      expect(
        InstantStatus.fromMap({'enabled': false, 'status': 'connected'}).state,
        InstantState.off,
      );
      expect(
        InstantStatus.fromMap({'enabled': false, 'status': 'unauthorized'})
            .state,
        InstantState.unauthorized,
      );
    });

    test('not on this platform: nothing is called', () async {
      final p = _FakePlatform();
      final off = InstantNotifications(platform: p, supported: false);
      await off.load();
      await off.configure(
        bridgeOffers: true,
        url: 'u',
        accessKey: 'k',
        systemEnabled: true,
      );
      expect(p.calls, isEmpty);
      expect(off.active, isFalse);
      off.dispose();
    });
  });

  group('background check (instant off)', () {
    late MemoryEventsCursorStore store;
    late _Sink sink;

    setUp(() {
      store = MemoryEventsCursorStore();
      sink = _Sink();
    });

    test(
      'first run records the cursor; later runs announce each end once',
      () async {
        var page = <String, dynamic>{
          'events': [],
          'last_id': 40,
          'reset': null,
          'more': false,
        };
        http.on('GET /api/events', (_) => jsonResponse(page));
        expect(
          await runEventsPoll(
            api: api,
            sink: sink,
            store: store,
            enabled: () async => true,
          ),
          0,
        );
        expect(http.last('GET /api/events').query, {'after': '0', 'once': '1'});
        expect(store.cursors.values.single, 40);
        page = {
          'events': [
            {'id': 41, 'type': 'task.done', 'data': data('c1')},
            {'id': 42, 'type': 'reply.done', 'data': data('c2', watched: true)},
            {'id': 43, 'type': 'notify', 'data': data('tove')},
            {
              'id': 44,
              'type': 'test',
              'data': {'title': 'Test'},
            },
          ],
          'last_id': 44,
          'reset': null,
          'more': false,
        };
        expect(
          await runEventsPoll(
            api: api,
            sink: sink,
            store: store,
            enabled: () async => true,
          ),
          2,
        );
        expect(http.last('GET /api/events').query['after'], '40');
        expect(sink.shown.map((n) => n.conversationId), ['c1', 'tove']);
        expect(store.cursors.values.single, 44);
        // The same message again (another source already claimed it): quiet.
        page = {
          ...page,
          'last_id': 45,
          'events': [
            {'id': 45, 'type': 'task.done', 'data': data('c1')},
          ],
        };
        expect(
          await runEventsPoll(
            api: api,
            sink: sink,
            store: store,
            enabled: () async => true,
          ),
          0,
        );
      },
    );

    test(
      'notifications off: the cursor moves, nothing is shown; offline: -1',
      () async {
        store.cursors[api.baseUrl.toString()] = 1;
        http.on(
          'GET /api/events',
          (_) => jsonResponse({
            'events': [
              {'id': 2, 'type': 'reply.done', 'data': data('c1')},
            ],
            'last_id': 2,
            'more': false,
          }),
        );
        expect(
          await runEventsPoll(
            api: api,
            sink: sink,
            store: store,
            enabled: () async => false,
          ),
          0,
        );
        expect(store.cursors.values.single, 2);
        http.failWith = Exception('offline');
        expect(
          await runEventsPoll(
            api: api,
            sink: sink,
            store: store,
            enabled: () async => true,
          ),
          -1,
        );
      },
    );
  });

  test('one banner per message, whichever source reports it first', () {
    final replies = BackgroundReplies();
    final n = ReplyNotifier(
      replies: replies,
      sink: NoopNotificationSink(),
      onScreenConversation: () => 'other',
      systemEnabled: () => true,
      appVisible: () => true,
    );
    const notice = ReplyNotice(
      kind: ReplyNoticeKind.task,
      conversationId: 'c1',
      messageId: 'm1',
    );
    expect(n.announce(notice), NoticeTarget.banner);
    expect(n.announce(notice), NoticeTarget.none); // the push, then the event
    n.dispose();
    replies.dispose();
  });

  test('ChatApi.testEvents reports open streams', () async {
    http.on(
      'POST /api/events/test',
      (_) => jsonResponse({'ok': true, 'id': 3, 'readers': 2}),
    );
    expect(await api.testEvents(), 2);
  });
}

class _FakePlatform implements InstantPlatform {
  final calls = <(String, Object?)>[];
  Map<Object?, Object?> status = {'enabled': true, 'status': 'connecting'};
  Future<Object?> Function(MethodCall call)? handler;

  @override
  Future<Map<Object?, Object?>?> invoke(String method, [Object? args]) async {
    calls.add((method, args));
    if (method == 'configure') {
      final on = (args as Map)['enabled'] == true;
      return {
        ...status,
        'enabled': on,
        'status': on ? status['status'] : 'off',
      };
    }
    if (method == 'status') return status;
    return null;
  }

  @override
  void setHandler(Future<Object?> Function(MethodCall call)? h) => handler = h;

  Future<void> send(String method, Object? args) async =>
      handler?.call(MethodCall(method, args));
}

class _Sink extends NoopNotificationSink {}
