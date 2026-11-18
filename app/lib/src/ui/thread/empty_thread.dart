import 'package:material_ui/material_ui.dart';

import '../../brand.dart';
import '../orb/orb.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'starter_marquee.dart';
import 'starter_prompts.dart';

/// The empty new chat (spec §2.2, round 4 starter rows).
///
/// Chat available: the greeting, two rows of large starter chips drifting
/// sideways in opposite directions ([StarterMarquee]) and a "Surprise me"
/// button. Phones keep the composer at the bottom and centre this group in
/// the space above it. Wide layouts with the composer centred
/// ([centredComposer] is its pill's rect in this widget's coordinates):
/// the greeting sits above the composer and the rows under it, a little
/// wider than the composer and fading at both ends.
///
/// Without text chat (an old bridge): the idle orb, a greeting and a note.
class EmptyThread extends StatelessWidget {
  const EmptyThread({
    super.key,
    required this.topInset,
    required this.bottomInset,
    required this.chatEnabled,
    required this.prompts,
    required this.onSuggestion,
    this.centredComposer,
    this.active = true,
  });

  final double topInset;
  final double bottomInset;
  final bool chatEnabled;
  final List<StarterPrompt> prompts;
  final ValueChanged<String> onSuggestion;
  final Rect? centredComposer;

  /// False pauses the drifting rows (a panel or live mode covers the chat).
  final bool active;

  /// The greeting; one string for both layouts.
  static String greeting(bool chatEnabled) =>
      chatEnabled ? 'What can I do for you?' : 'Talk to ${Brand.assistantName}';

  static const gutter = 16.0;

  /// How far the wide layout's rows reach past each side of the composer.
  static const wideOverhang = 120.0;

  @override
  Widget build(BuildContext context) {
    final centred = centredComposer;
    return centred == null ? _bottom(context) : _centred(context, centred);
  }

  Widget _note(HermesTokens t) => Text(
    'Tap the waveform to start live voice. Text chat needs a newer '
    '${Brand.serverName}.',
    style: t.row.copyWith(color: t.textMuted).hermesWeight(400),
    textAlign: TextAlign.center,
  );

  bool get _showStarters => chatEnabled && prompts.isNotEmpty;

  Widget _starters({double padding = gutter}) => _Entry(
    index: 1,
    child: StarterMarquee(
      key: const ValueKey('starter-chips'),
      prompts: prompts,
      active: active,
      padding: padding,
      onPick: (p) => onSuggestion(p.prompt),
    ),
  );

  Widget _greeting(HermesTokens t, {Key? key}) => Semantics(
    header: true,
    child: Text(
      greeting(chatEnabled),
      key: key,
      style: t.headline.copyWith(fontSize: 26, height: 32 / 26),
      textAlign: TextAlign.center,
    ),
  );

  Widget _bottom(BuildContext context) {
    final t = HermesTokens.of(context);
    // One scroll view for the greeting and the rows: when the keyboard (or
    // a multi-line draft) leaves too little room, they scroll instead of
    // sliding under the composer; with room, the group sits in the middle
    // of the space above the composer.
    return Padding(
      padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              children: [
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: gutter),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_showStarters) ...[
                        const HermesOrb(state: OrbState.idle, size: 96),
                        const SizedBox(height: 24),
                      ],
                      _greeting(t, key: const ValueKey('empty-greeting')),
                      if (!chatEnabled) ...[
                        const SizedBox(height: 8),
                        _note(t),
                      ],
                    ],
                  ),
                ),
                if (_showStarters) ...[const SizedBox(height: 24), _starters()],
                const Spacer(),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Wide: the greeting 28 dp above the composer, the rows 20 dp below it,
  /// centred on the composer and [wideOverhang] wider on each side.
  Widget _centred(BuildContext context, Rect pill) {
    final t = HermesTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final width = (pill.width + 2 * wideOverhang).clamp(0.0, box.maxWidth);
        final left = (pill.center.dx - width / 2).clamp(
          0.0,
          box.maxWidth - width,
        );
        return Stack(
          children: [
            Positioned(
              left: pill.left,
              width: pill.width,
              bottom: box.maxHeight - pill.top + 28,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _greeting(t, key: const ValueKey('empty-greeting')),
                  if (!chatEnabled) ...[const SizedBox(height: 8), _note(t)],
                ],
              ),
            ),
            if (_showStarters)
              Positioned(
                key: const ValueKey('starter-rows'),
                left: left,
                width: width,
                top: pill.bottom + 20,
                bottom: 0,
                child: SingleChildScrollView(
                  child: _starters(padding: pill.left - left),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The entry motion: fade in rising 8 dp, staggered by 40 ms.
class _Entry extends StatelessWidget {
  const _Entry({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Motion.of(context, Duration(milliseconds: 260 + 40 * index)),
    curve: Motion.emphasizedDecel,
    builder: (context, v, child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
    ),
    child: child,
  );
}
