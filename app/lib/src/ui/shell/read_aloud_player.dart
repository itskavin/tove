import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../../speech/speech.dart';
import '../interactive/interactive.dart' show hermesUiPlainText;
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../thread/message_actions.dart';

/// The thread's [ReadAloud] over the speech module's TTS controller.
class SpeechReadAloud implements ReadAloud {
  SpeechReadAloud(this.speech);

  final SpeechServices speech;

  TtsController get _tts => speech.tts;

  @override
  bool get available => true;

  @override
  String? get reading {
    final v = _tts.value;
    return v.isActive ? v.messageId : null;
  }

  @override
  Future<void> toggle(ChatMessage message) =>
      _tts.toggle(hermesUiPlainText(message.text), messageId: message.id);

  @override
  void addListener(VoidCallback listener) => _tts.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _tts.removeListener(listener);
}

/// The read-aloud capsule (chat-rendering-v2 §5.4): 48 dp tall, up to 320 dp
/// wide, centred 8 dp above the composer; play/pause, the first words with a
/// progress line, a speed toggle and close. Rises 8 dp and fades in over
/// 140 ms, out over 120 ms.
class ReadAloudPlayer extends StatelessWidget {
  const ReadAloudPlayer({super.key, required this.tts});

  final TtsController tts;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsPlaybackState>(
      valueListenable: tts,
      builder: (context, s, _) {
        final shown = s.isActive;
        return IgnorePointer(
          ignoring: !shown,
          child: AnimatedSlide(
            offset: shown ? Offset.zero : const Offset(0, 8 / 48),
            duration: Motion.of(
              context,
              Duration(milliseconds: shown ? 140 : 120),
            ),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: Motion.of(
                context,
                Duration(milliseconds: shown ? 140 : 120),
              ),
              child: shown ? _Capsule(tts: tts, s: s) : const SizedBox(),
            ),
          ),
        );
      },
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.tts, required this.s});

  final TtsController tts;
  final TtsPlaybackState s;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final playing = s.status == TtsStatus.playing;
    final loading = s.status == TtsStatus.loading;
    final speed = s.speed == s.speed.roundToDouble()
        ? '${s.speed.round()}×'
        : '${s.speed}×';
    return Semantics(
      container: true,
      label: 'Read aloud',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Material(
          color: t.surfaceHigh,
          shape: StadiumBorder(side: BorderSide(color: t.hairline)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 48,
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 6),
                    Semantics(
                      button: true,
                      label: playing ? 'Pause' : 'Play',
                      excludeSemantics: true,
                      child: GestureDetector(
                        onTap: tts.togglePause,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: t.text,
                            shape: BoxShape.circle,
                          ),
                          child: loading
                              ? Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: t.bg,
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 22,
                                  color: t.bg,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.caption,
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Speed $speed',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: tts.cycleSpeed,
                        customBorder: const StadiumBorder(),
                        child: SizedBox(
                          height: 48,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Center(
                              child: Text(
                                speed,
                                style: t.chip.copyWith(color: t.text),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Stop reading',
                      onPressed: tts.stop,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: t.textMuted,
                      ),
                    ),
                  ],
                ),
                // 2 dp progress along the inner bottom edge.
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 3,
                  child: ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(1),
                      child: LinearProgressIndicator(
                        value: s.progress,
                        minHeight: 2,
                        color: t.text,
                        backgroundColor: t.text.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
