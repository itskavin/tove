import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/platform/call_platform.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';

import 'fakes.dart';

void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late FakePlatform platform;
  late CallController call;

  CallController make({bool nativeSupported = true}) {
    platform = FakePlatform(supported: nativeSupported);
    return CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: platform,
      voice: () => 'juniper',
      timings: fastTimings,
      desktop: false,
    );
  }

  setUp(() {
    bridge = FakeBridge();
    call = make();
  });

  tearDown(() => call.dispose());

  Future<void> goLive() async {
    await call.start();
    expect(call.phase, CallPhase.connecting);
    transport.emit({'type': 'session.started'});
    await settle();
    expect(call.phase, CallPhase.live);
  }

  test('happy path: mic, native start, offer, session, answer, live', () async {
    await goLive();
    expect(transport.calls, ['mic', 'offer', 'answer']);
    expect(platform.calls, ['start:false']);
    expect(call.background, BackgroundSupport.native);
    final session = bridge.to('/api/session').single;
    expect(session.body, {'offer': 'v=0 offer', 'voice': 'juniper', 'ui': 2});
    expect(session.auth, 'Bearer $testKey');
    expect(transport.answer, 'v=0 answer');
  });

  group('warm start (round 8)', () {
    test('prewarm pings the bridge at most every 45 s and the call reuses '
        'its client', () async {
      var made = 0;
      call.dispose();
      call = CallController(
        apiFactory: () {
          made++;
          return bridge.api();
        },
        transportFactory: () => transport = FakeTransport(),
        platform: platform = FakePlatform(),
        voice: () => 'cove',
        timings: fastTimings,
        desktop: false,
      );
      call.prewarm();
      call.prewarm();
      await settle();
      expect(bridge.to('/api/session/warm'), hasLength(1));
      expect(made, 1);
      await goLive();
      expect(made, 1, reason: 'the warm client carries the call');
      expect(
        bridge.requests.where((r) => r.path == '/api/session'),
        hasLength(1),
      );
    });

    test('no warm ping during a call', () async {
      await goLive();
      call.prewarm();
      await settle();
      expect(bridge.to('/api/session/warm'), isEmpty);
    });

    test(
      'a call spends the warm session, so the next touch warms again',
      () async {
        call.prewarm();
        await settle();
        await goLive();
        await call.end();
        await settle();
        call.prewarm();
        await settle();
        expect(bridge.to('/api/session/warm'), hasLength(2));
      },
    );

    test('connect timing marks every stage in order', () async {
      await goLive();
      final t = call.connectTiming;
      expect(
        t.keys,
        containsAll(['microphone', 'native', 'offer', 'session', 'live']),
      );
      expect(t['microphone']!, lessThanOrEqualTo(t['offer']!));
      expect(t['offer']!, lessThanOrEqualTo(t['session']!));
      expect(t['session']!, lessThanOrEqualTo(t['live']!));
    });

    test('Android: the native call starts alongside the offer, and a slow '
        'one does not hold the session request', () async {
      final hold = Completer<void>();
      platform.holdStart = hold;
      unawaited(call.start());
      await settle();
      expect(
        bridge.requests.where((r) => r.path == '/api/session'),
        hasLength(1),
      );
      expect(call.phase, CallPhase.connecting);
      hold.complete();
      await settle();
      transport.emit({'type': 'session.started'});
      await settle();
      expect(call.phase, CallPhase.live);
      expect(call.background, BackgroundSupport.native);
    });
  });

  test('native call starts only after the microphone opened', () async {
    transport = FakeTransport();
    final hold = Completer<void>();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport..holdMic = hold,
      platform: platform = FakePlatform(),
      voice: () => 'cove',
      timings: fastTimings,
      desktop: false,
    );
    unawaited(call.start());
    await settle();
    expect(call.step, ConnectStep.microphone);
    expect(platform.calls, isEmpty);
    hold.complete();
    await settle();
    expect(platform.calls, ['start:false']);
    expect(bridge.to('/api/session'), hasLength(1));
  });

  test('microphone denied: error state, no native call, no session', () async {
    transport = FakeTransport()
      ..micError = const MicrophoneException(
        'Microphone permission was denied',
        denied: true,
      );
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport,
      platform: platform = FakePlatform(),
      voice: () => 'cove',
      timings: fastTimings,
      desktop: false,
    );
    await call.start();
    expect(call.phase, CallPhase.failed);
    expect(call.inCall, isFalse);
    expect(call.error, 'Microphone permission was denied');
    expect(platform.calls, isEmpty);
    expect(bridge.requests, isEmpty);
    expect(transport.closed, isTrue);
  });

  test(
    'ending during SDP setup cleans up and stops the late session',
    () async {
      bridge.holdSession = Completer<void>();
      unawaited(call.start());
      await settle();
      expect(call.step, ConnectStep.server);

      final ended = call.end();
      // The UI is idle immediately, not stuck connecting.
      expect(call.phase, CallPhase.idle);
      expect(call.inCall, isFalse);
      await settle();
      expect(transport.closed, isTrue);
      expect(platform.calls, ['start:false', 'end']);
      expect(bridge.to('/api/stop'), isEmpty);

      // The server finishes creating the session after the hang-up.
      bridge.holdSession!.complete();
      await ended;
      expect(bridge.to('/api/stop').single.body, {'session': 'sid1'});
      expect(transport.calls, isNot(contains('answer')));
      expect(call.phase, CallPhase.idle);
    },
  );

  test(
    'server error: failed state with honest message and full cleanup',
    () async {
      bridge.sessionStatus = 502;
      await call.start();
      expect(call.phase, CallPhase.failed);
      expect(call.error, contains('could not start'));
      expect(transport.closed, isTrue);
      expect(platform.calls, ['start:false', 'end']);
      expect(bridge.to('/api/stop'), isEmpty);
    },
  );

  test('wrong key is reported as such', () async {
    bridge.sessionStatus = 401;
    await call.start();
    expect(call.phase, CallPhase.failed);
    expect(call.error, contains('access key'));
  });

  test('no session.started in time: failed, session stopped', () async {
    await call.start();
    await settle(fastTimings.connect.inMilliseconds + 100);
    expect(call.phase, CallPhase.failed);
    expect(call.error, CallController.voiceConnectionFailed);
    expect(bridge.to('/api/stop').single.body['session'], 'sid1');
    expect(transport.closed, isTrue);
  });

  test('native start failure is surfaced but the call continues', () async {
    platform = FakePlatform()
      ..startError = const CallPlatformException('Service refused');
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: platform,
      voice: () => 'cove',
      timings: fastTimings,
      desktop: false,
    );
    await call.start();
    transport.emit({'type': 'session.started'});
    await settle();
    expect(call.phase, CallPhase.live);
    expect(call.notice, 'Service refused');
    expect(call.background, BackgroundSupport.limited);
  });

  test('unsupported platforms skip the native channel', () async {
    call = make(nativeSupported: false);
    await goLive();
    expect(platform.calls, isEmpty);
    await call.end();
    expect(platform.calls, isEmpty);
  });

  test('mute propagates to the track and the native call', () async {
    await goLive();
    call.toggleMute();
    expect(call.muted, isTrue);
    expect(transport.muted, isTrue);
    await settle(5);
    expect(platform.calls.last, 'update:true');

    // Mute from the notification / CallKit does not echo back.
    platform.onMute!(false);
    expect(call.muted, isFalse);
    expect(transport.muted, isFalse);
    await settle(5);
    expect(platform.calls.where((c) => c.startsWith('update')), [
      'update:true',
    ]);
  });

  test('end from native tears down and stops the session', () async {
    await goLive();
    platform.onEnd!();
    await settle();
    expect(call.phase, CallPhase.idle);
    expect(transport.closed, isTrue);
    expect(bridge.to('/api/stop').single.body['session'], 'sid1');
    expect(platform.calls.last, 'end');
  });

  test('native warning (notifications off) is shown; call is native', () async {
    platform.startWarning = 'Notifications are off.';
    await goLive();
    expect(call.notice, 'Notifications are off.');
    expect(call.background, BackgroundSupport.native);
  });

  test('mute toggled while the native call starts is synced after', () async {
    platform.holdStart = Completer<void>();
    unawaited(call.start());
    await settle(5);
    // Android: the native call starts alongside the offer (round 8).
    expect(platform.calls, ['start:false']);
    call.toggleMute();
    expect(transport.muted, isTrue);
    await settle(5);
    // Not sent while startCall is pending (native would drop it).
    expect(platform.calls, ['start:false']);
    platform.holdStart!.complete();
    await settle();
    expect(platform.calls, ['start:false', 'update:true']);
  });

  test('native mute is acknowledged only when a call applied it', () async {
    expect(platform.onMute!(true), isFalse);
    expect(call.muted, isFalse);
    await goLive();
    expect(platform.onMute!(true), isTrue);
    expect(call.muted, isTrue);
    expect(transport.muted, isTrue);
  });

  test('native end without a call still stops the native call', () async {
    platform.onEnd!();
    await settle(5);
    expect(platform.calls, ['end']);
    expect(call.phase, CallPhase.idle);
  });

  test('peer failure ends the call with "Connection lost"', () async {
    await goLive();
    transport.link$.add(TransportLink.failed);
    await settle();
    expect(call.phase, CallPhase.failed);
    expect(call.error, 'Connection lost');
    expect(bridge.to('/api/stop'), hasLength(1));
  });

  test('a brief disconnect within the grace period survives', () async {
    await goLive();
    transport.link$.add(TransportLink.disconnected);
    await settle(20);
    transport.link$.add(TransportLink.connected);
    await settle(fastTimings.disconnectGrace.inMilliseconds + 50);
    expect(call.phase, CallPhase.live);
  });

  test('transcript follows turn events', () async {
    await goLive();
    transport
      ..emit({
        'type': 'turn.created',
        'turn': {'role': 'user'},
      })
      ..emit({
        'type': 'input_transcript.added',
        'item': {'text': 'check the '},
      })
      ..emit({
        'type': 'input_transcript.added',
        'item': {'text': 'disk'},
      });
    await settle(5);
    expect(call.userSpeaking, isTrue);
    expect(call.transcript.single.text, 'check the disk');
    expect(call.transcript.single.live, isTrue);
    transport
      ..emit({
        'type': 'turn.done',
        'turn': {'role': 'user', 'transcript': 'Check the disk.'},
      })
      ..emit({
        'type': 'turn.created',
        'turn': {'role': 'assistant'},
      })
      ..emit({
        'type': 'output_transcript.added',
        'item': {'text': 'On it.'},
      });
    await settle(5);
    expect(call.userSpeaking, isFalse);
    expect(call.hermesSpeaking, isTrue);
    expect(call.transcript.map((e) => (e.speaker, e.text)), [
      (Speaker.user, 'Check the disk.'),
      (Speaker.hermes, 'On it.'),
    ]);
    await call.end();
    expect(call.transcript.every((e) => !e.live), isTrue);
  });

  group('transcript turns', () {
    void created(String role, String id) => transport.emit({
      'type': 'turn.created',
      'turn': {'role': role, 'id': id},
    });
    void chunk(String role, String text) => transport.emit({
      'type': role == 'user'
          ? 'input_transcript.added'
          : 'output_transcript.added',
      'item': {'text': text},
    });
    void done(String role, String id, String transcript) => transport.emit({
      'type': 'turn.done',
      'turn': {'role': role, 'id': id, 'transcript': transcript},
    });
    List<(Speaker, String)> said() => [
      for (final e in call.transcript) (e.speaker, e.text),
    ];

    // The screenshot: each turn's first chunk arrived before its
    // turn.created, and was kept as a turn of its own ("Can", "I'll", "Not").
    test(
      'a chunk before turn.created stays in its turn (screenshot)',
      () async {
        await goLive();
        chunk('user', 'Can');
        created('user', 'u1');
        chunk('user', ' you download');
        chunk('user', ' and can you download the entire internet');
        done(
          'user',
          'u1',
          'Can you download and can you download the entire internet',
        );
        chunk('assistant', "I'll");
        created('assistant', 'a1');
        chunk('assistant', ' check that quickly.');
        done('assistant', 'a1', "I'll check that quickly.");
        chunk('assistant', 'Not');
        created('assistant', 'a2');
        chunk('assistant', ' realistically.');
        done(
          'assistant',
          'a2',
          "Not realistically. It's enormous, constantly changing, and much "
              "of it isn't public.",
        );
        await settle(5);
        expect(said(), [
          (
            Speaker.user,
            'Can you download and can you download the entire internet',
          ),
          (Speaker.hermes, "I'll check that quickly."),
          (
            Speaker.hermes,
            "Not realistically. It's enormous, constantly changing, and much "
                "of it isn't public.",
          ),
        ]);
        expect(call.transcript.every((e) => !e.live), isTrue);
        expect(call.transcript.map((e) => e.turnId), ['u1', 'a1', 'a2']);
      },
    );

    test('the same words said twice stay two turns', () async {
      await goLive();
      created('user', 'u1');
      chunk('user', 'Can');
      done('user', 'u1', 'Can');
      created('user', 'u2');
      chunk('user', 'Can');
      done('user', 'u2', 'Can');
      created('assistant', 'a1');
      chunk('assistant', 'Yes.');
      done('assistant', 'a1', 'Yes.');
      created('assistant', 'a2');
      chunk('assistant', 'Yes.');
      done('assistant', 'a2', 'Yes.');
      await settle(5);
      expect(said(), [
        (Speaker.user, 'Can'),
        (Speaker.user, 'Can'),
        (Speaker.hermes, 'Yes.'),
        (Speaker.hermes, 'Yes.'),
      ]);
    });

    test('a replayed turn.created and a late chunk change nothing', () async {
      await goLive();
      created('assistant', 'a1');
      chunk('assistant', 'Hello');
      created('assistant', 'a1');
      chunk('assistant', ' there');
      done('assistant', 'a1', 'Hello there.');
      transport.emit({
        'type': 'output_transcript.added',
        'item': {'text': ' there', 'turn_id': 'a1'},
      });
      await settle(5);
      expect(said(), [(Speaker.hermes, 'Hello there.')]);
    });

    test('a barge-in keeps both partial turns in order', () async {
      await goLive();
      created('assistant', 'a1');
      chunk('assistant', 'The disk is');
      created('user', 'u1');
      chunk('user', 'Wait');
      done('assistant', 'a1', 'The disk is');
      done('user', 'u1', 'Wait, which disk?');
      await settle(5);
      expect(said(), [
        (Speaker.hermes, 'The disk is'),
        (Speaker.user, 'Wait, which disk?'),
      ]);
    });

    test(
      'a turn closed before its words arrived keeps them, in order',
      () async {
        await goLive();
        // u1's transcription lags: u2 starts before any of u1's words.
        created('user', 'u1');
        created('user', 'u2');
        chunk('user', 'And the backups');
        done('user', 'u2', 'And the backups?');
        done('user', 'u1', 'How full is NAS-01?');
        await settle(5);
        expect(said(), [
          (Speaker.user, 'How full is NAS-01?'),
          (Speaker.user, 'And the backups?'),
        ]);
        expect(call.transcript.map((e) => e.turnId), ['u1', 'u2']);
      },
    );

    test('a turn that ends with no words stays out', () async {
      await goLive();
      created('user', 'u1');
      created('user', 'u2');
      done('user', 'u1', '');
      chunk('user', 'Hello');
      done('user', 'u2', 'Hello.');
      await settle(5);
      expect(said(), [(Speaker.user, 'Hello.')]);
    });

    test('turn.done with no earlier events keeps the turn', () async {
      await goLive();
      done('user', 'u9', 'Are you there?');
      await settle(5);
      expect(said(), [(Speaker.user, 'Are you there?')]);
    });
  });

  test('voice model errors become a notice, not a dead call', () async {
    await goLive();
    transport.emit({
      'type': 'error',
      'error': {'message': 'rate limited'},
    });
    await settle(5);
    expect(call.phase, CallPhase.live);
    expect(call.notice, 'Voice error: rate limited');
  });

  test('levels are polled while live and zeroed on mute and end', () async {
    await goLive();
    await settle(60);
    expect(call.levels.value.input, 0.1);
    call.toggleMute();
    expect(call.levels.value.input, 0);
    await call.end();
    expect(call.levels.value.input, 0);
    expect(call.levels.value.output, 0);
  });

  test('speaker route applied when live on phones', () async {
    transport = FakeTransport()..speakerRoute = true;
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport,
      platform: platform = FakePlatform(),
      voice: () => 'cove',
      timings: fastTimings,
      desktop: false,
    );
    await call.start();
    transport.emit({'type': 'session.started'});
    await settle();
    expect(transport.speaker, [true]);
    await call.setSpeaker(false);
    expect(transport.speaker, [true, false]);
    expect(call.speakerOn, isFalse);
  });

  test('a second start while connecting is ignored', () async {
    bridge.holdSession = Completer<void>();
    unawaited(call.start());
    await settle();
    await call.start();
    expect(transport.calls.where((c) => c == 'mic'), hasLength(1));
    bridge.holdSession!.complete();
    await call.end();
  });

  test('a delegated task runs and its result is spoken', () async {
    await goLive();
    transport.emit({
      'type': 'delegation.created',
      'item': {
        'id': 'item1',
        'content': [
          {'type': 'input_text', 'text': 'How full is the disk on storage?'},
        ],
      },
    });
    await settle(60);
    final task = call.tasks.single;
    expect(task.status, TaskStatus.done);
    expect(bridge.to('/api/delegate').single.body, {
      'session': 'sid1',
      'text': 'How full is the disk on storage?',
    });
    final append = transport.sent.single;
    expect(append['type'], 'delegation.context.append');
    expect(append['delegation_item_id'], 'item1');
    expect(
      (append['content'] as List).single['text'],
      contains('The disk is 40% full.'),
    );
  });

  test('ending the call stops running tasks honestly', () async {
    bridge.defaultRunningPolls = 1000;
    await goLive();
    transport.emit({
      'type': 'delegation.created',
      'item': {
        'id': 'item1',
        'content': [
          {'type': 'input_text', 'text': 'Restart the media server please'},
        ],
      },
    });
    await settle(30);
    expect(call.tasks.single.status, TaskStatus.running);
    await call.end();
    expect(call.tasks.single.status, TaskStatus.stopped);
    final polls = bridge.to('/api/job').length;
    await settle(40);
    expect(bridge.to('/api/job').length, polls);
  });
}
