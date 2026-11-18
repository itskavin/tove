import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/call/farewell.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';

import '../fakes.dart';

void main() {
  group('isFarewell', () {
    for (final yes in [
      'Bye',
      'bye bye',
      'Bye-bye!',
      'Goodbye.',
      'Good bye, Tove',
      'Okay, bye.',
      'OK thanks, bye',
      'Thanks a lot, goodbye!',
      'Thank you so much. Bye.',
      'That’s all, bye',
      "That's all for now",
      "Alright, I'm done for now. Bye then.",
      'See you later',
      'see ya',
      'Talk to you later, Tove',
      'Catch you later',
      'Good night',
      'Okay, good night Tove, take care',
      'You can end the call',
      'Hang up',
      'Gotta go, bye',
      'No, that’s it, thanks. Bye!',
    ]) {
      test('ends: "$yes"', () => expect(isFarewell(yes), isTrue));
    }
    for (final no in [
      '',
      'How do I say bye in French?',
      'Say goodbye to the old server and wipe it',
      'Bye Bye Birdie lyrics',
      'What does goodbye mean in Japanese',
      'Good night routines for better sleep',
      "That's all I needed to know about the backups, what about NAS-01?",
      'Remind me to say bye to Alex tomorrow',
      'Okay so before you go, check the disks',
      'See you in the logs, what failed?',
      'Later today, plan my evening',
      'Hang up the laundry reminder at 6',
      'bye bye bye bye bye bye bye bye bye bye bye bye bye bye',
    ]) {
      test('keeps going: "$no"', () => expect(isFarewell(no), isFalse));
    }
  });

  group('the call ends after the farewell', () {
    late FakeBridge bridge;
    late FakeTransport transport;
    late CallController call;

    setUp(() {
      bridge = FakeBridge();
      call = CallController(
        apiFactory: bridge.api,
        transportFactory: () => transport = FakeTransport(),
        platform: FakePlatform(),
        voice: () => 'cove',
        timings: fastTimings,
        desktop: false,
      );
    });
    tearDown(() => call.dispose());

    Future<void> live() async {
      await call.start();
      transport.emit({'type': 'session.started'});
      await settle();
      expect(call.phase, CallPhase.live);
    }

    void turn(String role, String id, String text) {
      transport
        ..emit({
          'type': 'turn.created',
          'turn': {'id': id, 'role': role},
        })
        ..emit({
          'type': 'turn.done',
          'turn': {'id': id, 'role': role, 'transcript': text},
        });
    }

    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    test('user says bye, Tove says a short farewell, audio goes quiet: '
        'the call ends by itself', () async {
      await live();
      turn('user', 'u1', 'Okay thanks, bye!');
      await settle();
      expect(call.endingByFarewell, isTrue);
      // Tove's farewell plays (loud), then goes quiet.
      transport.levels = const AudioLevels(input: 0, output: 0.4);
      turn('assistant', 'a1', 'Bye Alex, talk soon.');
      await wait(120);
      expect(call.phase, CallPhase.live, reason: 'still playing');
      transport.levels = const AudioLevels(input: 0, output: 0);
      await wait(400);
      await settle();
      expect(call.phase, CallPhase.idle);
      expect(bridge.to('/api/stop'), hasLength(1));
    });

    test('no farewell from Tove in time: ends anyway', () async {
      await live();
      turn('user', 'u1', 'goodbye');
      await wait(450);
      await settle();
      expect(call.phase, CallPhase.idle);
    });

    test('a request that mentions bye keeps the call', () async {
      await live();
      turn('user', 'u1', 'How do I say bye in French?');
      turn('assistant', 'a1', 'Au revoir.');
      await wait(800);
      expect(call.phase, CallPhase.live);
      expect(call.endingByFarewell, isFalse);
    });

    test('speaking again after bye cancels it', () async {
      await live();
      turn('user', 'u1', 'bye');
      await settle();
      transport.emit({
        'type': 'turn.created',
        'turn': {'id': 'u2', 'role': 'user'},
      });
      await wait(800);
      expect(call.phase, CallPhase.live);
    });

    test('no level readings: ends after an estimate from the words', () async {
      await live();
      transport.levels = AudioLevels.unknown;
      turn('user', 'u1', 'bye');
      turn('assistant', 'a1', 'Bye!');
      await wait(700);
      await settle();
      expect(call.phase, CallPhase.idle);
    });

    test('a bye before the call is live does nothing', () async {
      unawaited(call.start());
      await settle();
      expect(call.phase, CallPhase.connecting);
      turn('user', 'u1', 'bye');
      await settle();
      expect(call.endingByFarewell, isFalse);
    });
  });
}
