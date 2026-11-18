import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/bridge/bridge_api.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/call/models.dart';

import 'fakes.dart';

/// Live-mode error classification and the call summary (spec §9.3, §9.7;
/// API.md "Start errors" and "Live calls linked to a chat").
void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late CallController call;
  String? conversation;

  setUp(() {
    bridge = FakeBridge();
    conversation = null;
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: FakePlatform(supported: false),
      voice: () => 'cove',
      conversationId: () => conversation,
      timings: fastTimings,
      desktop: true,
    );
  });
  tearDown(() => call.dispose());

  test('usage limit at start is its own error, with the reset time', () async {
    bridge
      ..sessionStatus = 429
      ..sessionError = {
        'error': 'usage_limit',
        'code': 'usage_limit',
        'message': 'GPT-Live usage limit reached',
        'retry_after_s': 7200,
      };
    await call.start();
    await settle();
    expect(call.phase, CallPhase.failed);
    expect(call.errorKind, CallErrorKind.usageLimit);
    expect(call.retryAfter, const Duration(hours: 2));
    expect(call.error, contains('usage limit'));
    expect(call.error, contains('2 h'));
    expect(call.error, isNot(contains('Connection lost')));
  });

  test('login expired is told apart from a wrong key', () async {
    bridge
      ..sessionStatus = 502
      ..sessionError = {
        'error': 'login_expired',
        'code': 'login_expired',
        'message': 'sign in again on the server',
      };
    await call.start();
    await settle();
    expect(call.errorKind, CallErrorKind.loginExpired);
    expect(call.error, CallController.loginExpiredMessage);

    bridge
      ..sessionStatus = 401
      ..sessionError = {'error': 'unauthorized', 'code': 'unauthorized'};
    await call.start();
    await settle();
    expect(call.errorKind, CallErrorKind.unauthorized);
  });

  test('an old bridge start failure stays generic', () async {
    bridge.sessionStatus = 502;
    await call.start();
    await settle();
    expect(call.errorKind, CallErrorKind.other);
    expect(call.error, contains('login may need renewing'));
  });

  test(
    'a usage-limit error on the data channel ends the call plainly',
    () async {
      await call.start();
      transport.emit({'type': 'session.started'});
      await settle();
      expect(call.phase, CallPhase.live);
      transport.emit({
        'type': 'error',
        'error': {
          'type': 'invalid_request_error',
          'message': 'You have reached your usage limit.',
        },
      });
      await settle();
      expect(call.phase, CallPhase.failed);
      expect(call.errorKind, CallErrorKind.usageLimit);
      expect(call.error, startsWith('You have reached your usage limit'));
      expect(transport.closed, isTrue);
      expect(bridge.to('/api/stop'), hasLength(1));
    },
  );

  test('other data-channel errors stay a notice', () async {
    await call.start();
    transport.emit({'type': 'session.started'});
    await settle();
    transport.emit({
      'type': 'error',
      'error': {'message': 'something odd'},
    });
    await settle();
    expect(call.phase, CallPhase.live);
    expect(call.notice, 'Voice error: something odd');
  });

  test('classifyVoiceError', () {
    expect(
      CallController.classifyVoiceError({'code': 'rate_limit_reached'}),
      CallErrorKind.usageLimit,
    );
    expect(
      CallController.classifyVoiceError({
        'message': 'Please log out and sign in again.',
      }),
      CallErrorKind.loginExpired,
    );
    expect(CallController.classifyVoiceError({'message': 'x'}), isNull);
    // A transient rate limit stays a notice (call_controller_test).
    expect(
      CallController.classifyVoiceError({'message': 'rate limited'}),
      isNull,
    );
  });

  test('links the call to the chat and reports a summary at the end', () async {
    conversation = 'c1';
    final summaries = <CallSummary>[];
    call.ended.listen(summaries.add);
    await call.start();
    transport.emit({'type': 'session.started'});
    await settle();
    expect(bridge.to('/api/session').single.body['conversation_id'], 'c1');
    transport.emit({
      'type': 'turn.created',
      'turn': {'role': 'user'},
    });
    transport.emit({
      'type': 'turn.done',
      'turn': {'role': 'user', 'transcript': 'How full is the disk?'},
    });
    transport.emit({
      'type': 'turn.created',
      'turn': {'role': 'assistant'},
    });
    transport.emit({
      'type': 'turn.done',
      'turn': {'role': 'assistant', 'transcript': 'Checking now.'},
    });
    await settle();
    await call.end();
    final s = summaries.single;
    expect(s.session, 'sid1');
    expect(s.conversationId, 'c1');
    expect(s.linked, isTrue);
    expect(s.transcript.map((e) => (e.speaker, e.text)), [
      (Speaker.user, 'How full is the disk?'),
      (Speaker.hermes, 'Checking now.'),
    ]);
    expect(s.errorKind, isNull);
  });

  test('without a chat the session body has no conversation_id', () async {
    await call.start();
    await settle();
    expect(
      bridge.to('/api/session').single.body.containsKey('conversation_id'),
      isFalse,
    );
  });

  test('BridgeException reads code first and keeps old human text', () {
    final v2 = BridgeApi.errorFrom(429, {
      'error': 'busy',
      'code': 'busy',
      'message': '2 replies are already streaming',
    });
    expect(v2.busy, isTrue);
    expect(v2.message, '2 replies are already streaming');
    final old = BridgeApi.errorFrom(429, {
      'error': 'two tasks are running',
      'code': 'busy',
    });
    expect(old.code, 'busy');
    expect(old.message, 'two tasks are running');
    final usage = BridgeApi.errorFrom(429, {
      'error': 'usage_limit',
      'code': 'usage_limit',
      'retry_after_s': null,
    });
    expect(usage.usageLimit, isTrue);
    expect(usage.busy, isFalse);
    expect(usage.retryAfter, isNull);
  });
}
