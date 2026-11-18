import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';
import 'package:tove_chat/src/ui/live/live_overlay.dart';
import 'package:tove_chat/src/ui/orb/orb.dart';
import 'package:tove_chat/src/ui/thread/follow_scroll.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:material_ui/material_ui.dart';

import '../fakes.dart';
import 'test_harness.dart';

void main() {
  group('follow scroll', () {
    Widget list(FollowScrollController c, int n, {double h = 100}) => themed(
      Scaffold(
        body: ListView.builder(
          controller: c,
          itemCount: n,
          itemBuilder: (_, i) => SizedBox(height: h, child: Text('$i')),
        ),
      ),
    );

    testWidgets('pins to the end while near it, in the same frame', (
      tester,
    ) async {
      phoneSize(tester);
      final c = FollowScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(list(c, 20));
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pump();
      await tester.pumpWidget(list(c, 21));
      // No post-frame jump needed: already at the new end.
      expect(c.position.pixels, c.position.maxScrollExtent);
    });

    testWidgets('leaves the reader alone when scrolled up past 160 dp', (
      tester,
    ) async {
      phoneSize(tester);
      final c = FollowScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(list(c, 30));
      c.jumpTo(c.position.maxScrollExtent - 400);
      await tester.pump();
      final before = c.position.pixels;
      await tester.pumpWidget(list(c, 31));
      expect(c.position.pixels, before);
      expect(c.atEnd, isFalse);
    });
  });

  testWidgets('message entry plays, but not under reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      themed(const MessageEntry(child: Text('hi')), reduce: false),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(FadeTransition), findsWidgets);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(
        of: find.byType(MessageEntry),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );

    await tester.pumpWidget(
      themed(
        const MessageEntry(key: ValueKey(2), child: Text('hi')),
        reduce: true,
      ),
    );
    expect(
      find.descendant(
        of: find.byType(MessageEntry),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  group('live state', () {
    late FakeBridge bridge;
    late FakeTransport transport;
    late CallController call;

    setUp(() {
      bridge = FakeBridge();
      call = CallController(
        apiFactory: bridge.api,
        transportFactory: () => transport = FakeTransport(),
        platform: FakePlatform(supported: false),
        voice: () => 'cove',
        timings: fastTimings,
        desktop: true,
      );
    });
    tearDown(() => call.dispose());

    test('orb state and status label follow the call', () async {
      expect(liveOrbState(call, awaitingReply: false), OrbState.ended);
      final starting = call.start();
      expect(liveOrbState(call, awaitingReply: false), OrbState.connecting);
      expect(liveStatus(call), 'Connecting…');
      await starting;
      transport.emit({'type': 'session.started'});
      await settle();
      call.levels.value = const AudioLevels(input: 0, output: 0);
      expect(liveOrbState(call, awaitingReply: false), OrbState.listening);
      expect(liveStatus(call), isNull, reason: 'no label while listening');
      expect(liveOrbState(call, awaitingReply: true), OrbState.thinking);
      expect(
        liveStatus(call),
        isNull,
        reason: 'work shows in the strip above the composer, not as a label',
      );

      call.levels.value = const AudioLevels(input: 0.3, output: 0);
      expect(liveOrbState(call, awaitingReply: false), OrbState.userSpeaking);
      call.levels.value = const AudioLevels(input: 0, output: 0.2);
      expect(
        liveOrbState(call, awaitingReply: false),
        OrbState.assistantSpeaking,
      );

      call.levels.value = const AudioLevels(input: 0, output: 0);
      call.toggleMute();
      expect(liveOrbState(call, awaitingReply: false), OrbState.muted);
      expect(liveStatus(call), 'Muted');
    });

    test('unknown levels never fake speech', () async {
      await call.start();
      transport.emit({'type': 'session.started'});
      await settle();
      call.levels.value = AudioLevels.unknown;
      expect(liveOrbState(call, awaitingReply: false), OrbState.listening);
    });

    test('a running task thinks without a label under the orb', () async {
      bridge.defaultRunningPolls = 50;
      await call.start();
      transport.emit({'type': 'session.started'});
      await settle();
      transport.levels = AudioLevels.silent;
      transport.emit({
        'type': 'delegation.created',
        'item': {
          'id': 'd1',
          'content': [
            {'text': 'run the backup check on NAS-01'},
          ],
        },
      });
      await settle(40);
      expect(call.tasks.single.seconds, 3);
      expect(liveStatus(call), isNull);
      expect(liveOrbState(call, awaitingReply: false), OrbState.thinking);
    });

    test('failed calls show their own message', () async {
      bridge
        ..sessionStatus = 502
        ..sessionError = {'error': 'login_expired', 'code': 'login_expired'};
      await call.start();
      await settle();
      expect(liveOrbState(call, awaitingReply: false), OrbState.error);
      expect(liveStatus(call), CallController.loginExpiredMessage);
    });
  });
}
