import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/prefs_store.dart';
import 'package:tove_chat/src/sync/sync_events.dart';

import '../chat/fake_http.dart';

Map<String, dynamic> _conv(String id, String title, {int updated = 1}) => {
  'id': id,
  'title': title,
  'pinned': false,
  'kind': 'text',
  'created': 1794691021626,
  'updated': 1794691021626 + updated,
};

BridgeEvent _event(String type, Map<String, dynamic> data, {int id = 1}) =>
    BridgeEvent.fromJson(type, id, data);

void main() {
  late FakeHttp net;
  late ConversationsController list;

  setUp(() async {
    net = FakeHttp()
      ..on(
        'GET /api/conversations',
        (_) => jsonResponse({
          'conversations': [_conv('c1', 'Old title'), _conv('c2', 'Other')],
          'next_cursor': null,
        }),
      );
    list = ConversationsController(
      api: ChatApi(baseUrl: chatTestBase, accessKey: chatTestKey, client: net),
    );
    await list.refresh();
  });

  tearDown(() => list.dispose());

  test('events from other devices update the list in place', () {
    var effect = applySyncEvent(
      _event('conversation.created', {
        'conversation_id': 'c3',
        'conversation': _conv('c3', 'New from the PC', updated: 99),
        'origin': 'pc-1',
      }),
      list,
      ownDevice: 'phone-1',
      openId: 'c1',
    );
    expect(effect, SyncEffect.list);
    expect(list.conversations.first.title, 'New from the PC');

    applySyncEvent(
      _event('conversation.title', {
        'conversation_id': 'c2',
        'title': 'Renamed elsewhere',
        'conversation': _conv('c2', 'Renamed elsewhere'),
      }),
      list,
      ownDevice: 'phone-1',
      openId: 'c1',
    );
    expect(list.byId('c2')!.title, 'Renamed elsewhere');

    effect = applySyncEvent(
      _event('conversation.deleted', {'conversation_id': 'c2'}),
      list,
      ownDevice: 'phone-1',
      openId: 'c1',
    );
    expect(list.byId('c2'), isNull);
    expect(effect, SyncEffect.list);
  });

  test('a new message in the open chat re-reads it', () {
    final e = _event('message.created', {
      'conversation_id': 'c1',
      'message_id': 'm9',
      'message': {'id': 'm9', 'role': 'user', 'text': 'hi'},
      'conversation': _conv('c1', 'Old title', updated: 50),
    });
    expect(
      applySyncEvent(e, list, ownDevice: 'phone-1', openId: 'c1'),
      SyncEffect.openChat,
    );
    // Another chat open: only the list.
    expect(
      applySyncEvent(e, list, ownDevice: 'phone-1', openId: 'c2'),
      SyncEffect.list,
    );
  });

  test("this device's own events are skipped", () {
    final e = _event('conversation.title', {
      'conversation_id': 'c1',
      'title': 'Mine',
      'conversation': _conv('c1', 'Mine'),
      'origin': 'phone-1',
    });
    expect(
      applySyncEvent(e, list, ownDevice: 'phone-1', openId: 'c1'),
      SyncEffect.none,
    );
    expect(list.byId('c1')!.title, 'Old title');
    // Not a sync event at all.
    expect(
      applySyncEvent(
        _event('reply.done', {'conversation_id': 'c1'}),
        list,
        ownDevice: 'phone-1',
        openId: 'c1',
      ),
      SyncEffect.none,
    );
  });

  test('every request carries X-Device-Id', () async {
    final api = ChatApi(
      baseUrl: chatTestBase,
      accessKey: chatTestKey,
      client: net,
    )..deviceId = 'phone-1';
    await api.listConversations();
    expect(net.requests.last.headers['X-Device-Id'], 'phone-1');
  });

  test('the install id is stable and well-formed', () async {
    final prefs = MemoryPrefsStore();
    final a = await installDeviceId(prefs);
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{1,64}$')));
    expect(await installDeviceId(prefs), a);
  });
}
