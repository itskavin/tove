import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/test_harness.dart';

export '../ui/test_harness.dart';

/// A widget test with semantics on (the tests find controls by label).
void semanticsTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      final h = tester.ensureSemantics();
      try {
        await body(tester);
      } finally {
        h.dispose();
      }
    });

class RecordingSink implements FeedbackSink {
  final haptics = <Haptic>[];
  @override
  void haptic(Haptic h) => haptics.add(h);
  @override
  void cue(Cue c) {}
}

/// A scripted [ComposerDictation].
class FakeDictation extends ChangeNotifier implements ComposerDictation {
  @override
  ComposerDictationPhase phase = ComposerDictationPhase.idle;
  @override
  String partial = '';
  @override
  String stablePrefix = '';
  @override
  String? finalText;
  @override
  double level = 0;
  @override
  ComposerDictationError? error;
  @override
  bool available = true;

  final calls = <String>[];

  /// What [start] does: listen, or fail with this error.
  ComposerDictationError? startError;

  /// Last [continuous] value set (a tap that became a hold).
  bool continuousOn = false;
  int warmUps = 0;

  @override
  set continuous(bool on) {
    continuousOn = on;
    calls.add('continuous:$on');
  }

  @override
  void warmUp() => warmUps++;

  @override
  Future<void> start({bool continuous = false}) async {
    continuousOn = continuous;
    calls.add(continuous ? 'start:continuous' : 'start');
    phase = ComposerDictationPhase.starting;
    notifyListeners();
    if (startError != null) {
      phase = ComposerDictationPhase.idle;
      error = startError;
      notifyListeners();
      return;
    }
    phase = ComposerDictationPhase.listening;
    notifyListeners();
  }

  void hear(String words, {double level = 0.6}) {
    partial = words;
    this.level = level;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    phase = ComposerDictationPhase.idle;
    finalText = partial;
    level = 0;
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    phase = ComposerDictationPhase.idle;
    partial = '';
    level = 0;
    notifyListeners();
  }

  /// The engine ended by itself with [e].
  void failWith(ComposerDictationError e) {
    phase = ComposerDictationPhase.idle;
    error = e;
    notifyListeners();
  }

  @override
  void acknowledge() {
    error = null;
    finalText = null;
  }
}

/// Owns the composer's inputs and records what it reports.
class ComposerRig {
  ComposerRig({
    this.attachments,
    this.dictation,
    this.attachmentsSupported = true,
    this.webSearchSupported = true,
  });

  final AttachmentController? attachments;
  final FakeDictation? dictation;
  final bool attachmentsSupported;
  final bool webSearchSupported;

  final text = ComposerTextController();
  final focus = FocusNode();
  final events = <String>[];
  final notices = <String>[];
  final sent = <ComposerMessage>[];
  final sink = RecordingSink();
  ReplyEffort effort = ReplyEffort.medium;
  bool webSearch = false;
  bool readAloud = false;
  final settings = SettingsController(
    keys: MemoryKeyStore(),
    prefs: MemoryPrefsStore(),
  );

  void dispose() {
    text.dispose();
    focus.dispose();
  }

  Widget build({
    bool live = false,
    bool reduce = false,
    double textScale = 1,
    Brightness brightness = Brightness.dark,
    bool withSubmit = true,
    ComposerDictation? dictationOverride,
  }) {
    return themed(
      brightness: brightness,
      reduce: reduce,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: FeedbackScope(
            feedback: AppFeedback(settings: settings, sink: sink, mobile: true),
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Composer(
                    controller: text,
                    focusNode: focus,
                    live: live,
                    streaming: false,
                    chatEnabled: true,
                    effortEnabled: true,
                    effort: effort,
                    onEffort: (e) => setState(() {
                      effort = e;
                      events.add('effort:${e.name}');
                    }),
                    onSend: (t) => events.add('send:$t'),
                    onStop: () => events.add('stop'),
                    onStartLive: () => events.add('live'),
                    muted: false,
                    onMute: () {},
                    onEnd: () {},
                    onMore: () => events.add('more'),
                    desktopKeys: false,
                    attachmentsSupported: attachmentsSupported,
                    attachments: attachments,
                    onSubmit: withSubmit ? sent.add : null,
                    webSearchSupported: webSearchSupported,
                    webSearch: webSearch,
                    onWebSearch: (v) => setState(() {
                      webSearch = v;
                      events.add('web:$v');
                    }),
                    readAloud: readAloud,
                    onReadAloud: (v) => setState(() {
                      readAloud = v;
                      events.add('aloud:$v');
                    }),
                    onVoiceSettings: () => events.add('voice-settings'),
                    dictation: dictationOverride ?? dictation,
                    onNotice: notices.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
