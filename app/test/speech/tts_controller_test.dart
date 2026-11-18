import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/speech/speech.dart';

import 'speech_fakes.dart';

void main() {
  late FakeSpeechPlatform platform;
  late FakeTtsEngine engine;
  late TtsController tts;

  TtsController make({TtsSelection Function()? select, int lookahead = 2}) =>
      TtsController(
        platform: platform,
        select: () async => select?.call() ?? TtsSelection(engine),
        lookahead: lookahead,
      );

  setUp(() {
    platform = FakeSpeechPlatform();
    engine = FakeTtsEngine();
    tts = make();
  });

  tearDown(() => tts.dispose());

  const reply = 'First sentence here. Second one follows! Third? Fourth and last.';

  test('reads sentence by sentence and finishes idle', () async {
    expect(await tts.speak(reply, messageId: 'm1'), isTrue);
    await pump();
    expect(tts.value.status, TtsStatus.playing);
    expect(tts.value.messageId, 'm1');
    expect(tts.value.sentences, hasLength(4));
    expect(platform.calls, contains('focus'));

    for (var i = 0; i < 4; i++) {
      expect(tts.value.sentenceIndex, i);
      expect(tts.value.currentSentence!.text, isNotEmpty);
      engine.finishNext();
      await pump();
    }
    expect(tts.value.status, TtsStatus.idle);
    expect(engine.synthesized, [
      'First sentence here.',
      'Second one follows!',
      'Third?',
      'Fourth and last.',
    ]);
    expect(platform.calls.last, 'abandonFocus');
  });

  test('synthesis stays at most lookahead sentences ahead', () async {
    await tts.speak(reply);
    await pump();
    // Sentence 0 playing, 1 and 2 synthesised ahead; 3 waits.
    expect(engine.synthesized, hasLength(3));
    engine.finishNext();
    await pump();
    expect(engine.synthesized, hasLength(4));
  });

  test('progress and RTF are reported', () async {
    await tts.speak(reply);
    await pump();
    expect(tts.value.progress, 0);
    expect(tts.value.lastRtf, closeTo(0.5, 1e-9));
    expect(tts.value.meanRtf, closeTo(0.5, 1e-9));
    expect(tts.value.firstAudioLatency, isNotNull);
    engine.finishNext();
    await pump();
    expect(tts.value.progress, greaterThan(0));
    expect(tts.value.progress, lessThan(1));
  });

  test('pause and resume mid-sentence engines', () async {
    await tts.speak(reply);
    await pump();
    await tts.pause();
    expect(tts.value.status, TtsStatus.paused);
    expect(tts.value.pauseReason, TtsPauseReason.user);
    expect(engine.log, contains('pause'));
    await tts.resume();
    expect(tts.value.status, TtsStatus.playing);
    expect(engine.log.last, 'resume');
    engine.finishNext();
    await pump();
    expect(tts.value.sentenceIndex, 1);
  });

  test('engines that cannot resume replay the interrupted sentence', () async {
    engine = FakeTtsEngine(kind: TtsEngineKind.system, resumesMidSentence: false);
    tts.dispose();
    tts = make();
    await tts.speak(reply);
    await pump();
    engine.finishNext(); // sentence 0 heard
    await pump();
    await tts.pause();
    expect(engine.log, contains('stop'));
    final before = engine.synthesized.length;
    await tts.resume();
    await pump();
    expect(engine.synthesized.sublist(before).first, 'Second one follows!');
    expect(tts.value.sentenceIndex, 1);
  });

  test('transient focus loss pauses and focus gain resumes', () async {
    await tts.speak(reply);
    await pump();
    platform.push(const AudioFocusEvent(AudioFocusChange.lossTransient));
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    expect(tts.value.pauseReason, TtsPauseReason.audioFocus);
    platform.push(const AudioFocusEvent(AudioFocusChange.gain));
    await pump();
    expect(tts.value.status, TtsStatus.playing);
  });

  test('permanent focus loss and unplugged headphones stay paused', () async {
    await tts.speak(reply);
    await pump();
    platform.push(const AudioFocusEvent(AudioFocusChange.loss));
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    platform.push(const AudioFocusEvent(AudioFocusChange.gain));
    await pump();
    expect(tts.value.status, TtsStatus.paused);

    await tts.resume();
    platform.push(const AudioBecomingNoisyEvent());
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    expect(tts.value.pauseReason, TtsPauseReason.noisy);
  });

  test('focus refused means nothing plays', () async {
    platform.focusGranted = false;
    expect(await tts.speak(reply), isFalse);
    expect(tts.value.status, TtsStatus.error);
    expect(engine.playing, isEmpty);
  });

  test('live mode pauses reading, blocks resume and new reads', () async {
    await tts.speak(reply);
    await pump();
    tts.liveModeActive = true;
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    expect(tts.value.pauseReason, TtsPauseReason.liveMode);
    expect(platform.calls.last, 'abandonFocus');
    await tts.resume();
    expect(tts.value.status, TtsStatus.paused);
    // Focus coming back during live voice does not resume either.
    platform.push(const AudioFocusEvent(AudioFocusChange.gain));
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    expect(await tts.speak(reply), isFalse);
    tts.autoReadReplies = true;
    await tts.onReplyFinished('m2', reply);
    expect(tts.value.status, TtsStatus.paused, reason: 'auto-read is blocked too');
    tts.liveModeActive = false;
    await pump();
    expect(tts.value.status, TtsStatus.paused, reason: 'no auto-resume');
    await tts.resume();
    expect(tts.value.status, TtsStatus.playing);
    expect(await tts.speak(reply), isTrue);
  });

  test('a call (transient focus loss) pauses and resumes after it', () async {
    engine = FakeTtsEngine(kind: TtsEngineKind.system, resumesMidSentence: false);
    tts.dispose();
    tts = make();
    await tts.speak(reply);
    await pump();
    platform.push(const AudioFocusEvent(AudioFocusChange.lossTransient));
    await pump();
    expect(tts.value.status, TtsStatus.paused);
    final before = engine.synthesized.length;
    platform.push(const AudioFocusEvent(AudioFocusChange.gain));
    await pump();
    expect(tts.value.status, TtsStatus.playing);
    // The interrupted sentence is read again from its start.
    expect(engine.synthesized[before], 'First sentence here.');
  });

  test('auto read only when enabled', () async {
    await tts.onReplyFinished('m1', reply);
    expect(tts.value.status, TtsStatus.idle);
    tts.autoReadReplies = true;
    await tts.onReplyFinished('m1', reply);
    await pump();
    expect(tts.value.status, TtsStatus.playing);
  });

  test('stop drops queued audio and old completions are ignored', () async {
    await tts.speak(reply);
    await pump();
    await tts.stop();
    expect(tts.value.status, TtsStatus.idle);
    expect(engine.queued, 0);
  });

  test('a new reply replaces the current one', () async {
    await tts.speak(reply, messageId: 'a');
    await pump();
    await tts.speak('Other text.', messageId: 'b');
    await pump();
    expect(tts.value.messageId, 'b');
    engine.finishNext();
    await pump();
    expect(tts.value.status, TtsStatus.idle);
  });

  test('toggle stops the message being read', () async {
    await tts.toggle(reply, messageId: 'a');
    await pump();
    expect(tts.value.isActive, isTrue);
    await tts.toggle(reply, messageId: 'a');
    expect(tts.value.isActive, isFalse);
  });

  test('speed change restarts the current sentence at the new speed', () async {
    await tts.speak(reply);
    await pump();
    await tts.cycleSpeed();
    await pump();
    expect(tts.value.speed, 1.25);
    expect(engine.speeds.last, 1.25);
    expect(engine.synthesized.where((s) => s == 'First sentence here.'), hasLength(2));
  });

  test('falls back when the chosen engine cannot prepare', () async {
    final broken = FakeTtsEngine(failPrepare: true);
    final system = FakeTtsEngine(kind: TtsEngineKind.system);
    tts.dispose();
    tts = make(select: () => TtsSelection(broken, fallback: system));
    expect(await tts.speak(reply), isTrue);
    await pump();
    expect(tts.value.engine, TtsEngineKind.system);
    expect(tts.value.fallbackReason, 'model missing');
    expect(system.playing, isNotEmpty);
  });

  test('nothing speakable starts nothing', () async {
    expect(await tts.speak('```\ncode only\n```\nhttps://example.com'), isTrue);
    // "Code block skipped." is still read; a pure URL is not.
    expect(await tts.speak('https://example.com'), isFalse);
  });

  test('releases engines when idle', () async {
    await tts.speak('One.');
    await pump();
    engine.finishNext();
    await pump();
    await tts.releaseEngines();
    expect(engine.released, 1);
  });
}
