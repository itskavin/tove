import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../attachments/attachment.dart';
import '../../attachments/attachment_controller.dart';
import '../../brand.dart';
import '../../config.dart';
import '../../settings/settings.dart';
import '../common/glass.dart';
import '../feedback.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'action_button.dart';
import 'attachment_strip.dart';
import 'composer_text_controller.dart';
import 'dictation.dart';
import 'dictation_hold.dart';
import 'dictation_mic.dart';
import 'effort_slider.dart';
import 'mic_hold.dart';
import 'plus_tray.dart';

export 'action_button.dart' show ComposerAction, composerActionFor;
export 'composer_text_controller.dart';
export 'dictation.dart';
export 'mic_hold.dart' show MicHoldMachine;

/// What the composer sends when [Composer.onSubmit] is set.
@immutable
class ComposerMessage {
  const ComposerMessage({
    required this.text,
    this.attachments = const [],
    this.webSearch = false,
  });

  /// Trimmed; may be empty when there are attachments.
  final String text;

  /// Uploaded ids to put in `message.attachments`.
  final List<UploadedAttachment> attachments;

  /// Send `web_search: true` with this message.
  final bool webSearch;
}

/// The bottom composer (spec §5.5, §5.6, §6.4, §6.7, §6.9).
///
/// One widget for both modes, so the change between them is a morph: in text
/// mode a full-width `surface` pill with +, an expanding field, a mic and the
/// waveform/send/stop action button; in live mode a glass pill (+, "Ask
/// Hermes", effort gauge) with a mute circle and the light end circle. From
/// a text scale of 1.6 the live pill takes its own line (§8.3).
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.live,
    required this.streaming,
    required this.chatEnabled,
    required this.effortEnabled,
    required this.effort,
    required this.onEffort,
    required this.onSend,
    required this.onStop,
    required this.onStartLive,
    required this.muted,
    this.callFailed = false,
    required this.onMute,
    required this.onEnd,
    required this.onMore,
    this.actionKey,
    this.liveAvailable = true,
    this.attachmentsSupported = false,
    this.desktopKeys,
    this.attachments,
    this.onSubmit,
    this.webSearchSupported = false,
    this.webSearch = false,
    this.onWebSearch,
    this.readAloud = false,
    this.onReadAloud,
    this.onVoiceSettings,
    this.dictation,
    this.onNotice,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Live mode is shown (the morph runs when this changes).
  final bool live;

  /// A text reply is streaming (the action button shows stop).
  final bool streaming;

  /// Typing is possible: the bridge has `/api/chat`.
  final bool chatEnabled;
  final bool effortEnabled;
  final ReplyEffort effort;
  final ValueChanged<ReplyEffort> onEffort;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final VoidCallback onStartLive;
  final bool muted;

  /// The live call failed (usage limit, network…): only the error, Try again
  /// and End stay, so the pill and mute fade out and stop taking input.
  final bool callFailed;
  final VoidCallback onMute;
  final VoidCallback onEnd;

  /// "More" in the plus menu: open Settings.
  final VoidCallback onMore;

  /// Placed on the action button so the live orb can fly from it.
  final GlobalKey? actionKey;
  final bool liveAvailable;
  final bool attachmentsSupported;

  /// Enter sends and Shift+Enter adds a line; defaults to desktop and web.
  final bool? desktopKeys;

  /// Staged attachments. The tray's Camera, Photos and Files work only with
  /// a controller and [attachmentsSupported]; otherwise they say
  /// "Needs a newer server".
  final AttachmentController? attachments;

  /// Sends text, attachment ids and the web-search flag. When null,
  /// [onSend] gets the text alone (and attachments cannot be sent).
  final ValueChanged<ComposerMessage>? onSubmit;

  /// Capabilities report `web_search: true`; the tray then shows
  /// "Search the web".
  final bool webSearchSupported;
  final bool webSearch;

  /// The flag applies to one message: the composer turns it off after
  /// sending.
  final ValueChanged<bool>? onWebSearch;

  /// "Read replies aloud" (the speech module reads the setting). The row is
  /// shown only with [onReadAloud].
  final bool readAloud;
  final ValueChanged<bool>? onReadAloud;

  /// The tray's last row: "Voice and speech settings" when set, otherwise
  /// "Settings" ([onMore]).
  final VoidCallback? onVoiceSettings;

  /// In-app dictation for the mic. Without it (or when unavailable) the mic
  /// focuses the field so the keyboard's voice key can be used.
  final ComposerDictation? dictation;

  /// Limits, picker and dictation errors. Defaults to a snack bar.
  final ValueChanged<String>? onNotice;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> with TickerProviderStateMixin {
  static const _enterMs = 340.0;
  late final AnimationController _live = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: widget.live ? 1 : 0,
  );
  late final AnimationController _effortCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 220),
  );
  // The + tray: a spring open, a 160 ms exit (§5.1). Slightly over 1 so
  // the spring may overshoot.
  late final AnimationController _trayCtl = AnimationController(
    vsync: this,
    upperBound: 1.1,
  )..addStatusListener(_onTrayStatus);
  final _trayPortal = OverlayPortalController();
  final _trayLink = LayerLink();
  final _trayGroup = Object();
  bool _trayOpen = false;

  final _pillKey = GlobalKey();
  final _gaugeKey = GlobalKey();
  final _stackKey = GlobalKey();
  bool _effortOpen = false;
  Rect? _gaugeRect;
  ReplyEffort? _beforeHigh;

  // Dictation: the text before the session and where its words go.
  String? _dictBase;
  String _dictSep = '';
  ComposerDictationPhase _dictPhase = ComposerDictationPhase.idle;

  // Press and hold on the mic (mic_hold.dart): release sends.
  final _hold = MicHoldMachine();
  Timer? _holdTimer;
  _Press _press = _Press.none;
  bool _micDown = false;

  /// Non-null while the hold panel shows.
  HoldPanelMode? _holdMode;

  /// Send what dictation produced once it is final (released, or Send in
  /// hands-free).
  bool _sendWhenDone = false;
  final _holdPortal = OverlayPortalController();
  late final _micGestures = <Type, GestureRecognizerFactory>{
    MicPressRecognizer:
        GestureRecognizerFactoryWithHandlers<MicPressRecognizer>(
          () => MicPressRecognizer(debugOwner: this, enabled: () => _micOn),
          (r) => r
            ..onDown = _onMicDown
            ..onMove = _onMicMove
            ..onUp = _onMicUp
            ..onCancel = _onMicCancel,
        ),
  };

  bool get effortOpen => _effortOpen;
  bool get trayOpen => _trayOpen;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.attachments?.addListener(_onAttachments);
    widget.dictation?.addListener(_onDictation);
    widget.dictation?.warmUp();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
    if (oldWidget.attachments != widget.attachments) {
      oldWidget.attachments?.removeListener(_onAttachments);
      widget.attachments?.addListener(_onAttachments);
    }
    if (oldWidget.dictation != widget.dictation) {
      oldWidget.dictation?.removeListener(_onDictation);
      widget.dictation?.addListener(_onDictation);
      _dictBase = null;
      _dictPhase = widget.dictation?.phase ?? ComposerDictationPhase.idle;
      _endHold();
      widget.dictation?.warmUp();
    }
    if (oldWidget.live != widget.live) {
      final reduced = Motion.reduced(context);
      _live.duration = reduced
          ? Motion.reducedDuration
          : const Duration(milliseconds: 340);
      widget.live ? _live.forward() : _live.reverse();
      if (!widget.live && _effortOpen) closeEffort();
      closeTray();
      if (widget.live && _dictating) widget.dictation?.cancel();
      if (widget.live) _endHold();
    }
    if (widget.callFailed && !oldWidget.callFailed && _effortOpen) {
      closeEffort();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.attachments?.removeListener(_onAttachments);
    widget.dictation?.removeListener(_onDictation);
    if (_dictating) widget.dictation?.cancel();
    _holdTimer?.cancel();
    _live.dispose();
    _effortCtl.dispose();
    _trayCtl.dispose();
    super.dispose();
  }

  bool _hadText = false;
  void _onText() {
    final has = widget.controller.text.trim().isNotEmpty;
    final long = widget.controller.text.length >= 7000;
    if (has != _hadText || long) {
      _hadText = has;
      setState(() {});
    }
  }

  void _onAttachments() {
    if (mounted) setState(() {});
  }

  bool get _hasText => widget.controller.text.trim().isNotEmpty;

  bool get _hasAttachments =>
      _attachmentsOn && (widget.attachments?.isNotEmpty ?? false);

  bool get _attachmentsOn =>
      widget.attachmentsSupported &&
      widget.attachments != null &&
      widget.onSubmit != null;

  /// Something to send, and every upload finished.
  bool get _canSend =>
      widget.chatEnabled &&
      (_hasText || _hasAttachments) &&
      (!_hasAttachments || widget.attachments!.ready);

  bool get _desktopKeys =>
      widget.desktopKeys ??
      (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Sends what is in the composer. [viaButton]: the Send button was
  /// pressed, so the on-screen keyboard closes once the message is accepted
  /// (Enter keeps the focus for the next message; a refused send keeps the
  /// draft and the focus).
  void _send({bool viaButton = false}) {
    if (!_canSend) return;
    final text = widget.controller.text.trim();
    if (_dictating) {
      // Sending ends dictation; what is in the field is what goes.
      _dictBase = null;
      widget.dictation?.cancel();
    }
    _endHold();
    _setPending(null);
    final submit = widget.onSubmit;
    if (submit != null) {
      final atts = _hasAttachments
          ? widget.attachments!.uploaded
          : const <UploadedAttachment>[];
      final web = widget.webSearchSupported && widget.webSearch;
      widget.controller.clear();
      if (_hasAttachments) widget.attachments!.clear();
      submit(ComposerMessage(text: text, attachments: atts, webSearch: web));
      if (web) widget.onWebSearch?.call(false);
      if (viaButton) _closeKeyboard();
      return;
    }
    if (text.isEmpty) return;
    widget.controller.clear();
    widget.onSend(text);
    if (viaButton) _closeKeyboard();
  }

  /// Closes the on-screen keyboard after a Send tap: where one is showing
  /// (its inset is up) or the platform uses one. A desktop with a hardware
  /// keyboard keeps the field focused.
  void _closeKeyboard() {
    if (!mounted) return;
    final inset = MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0;
    final touchPlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (inset > 0 || touchPlatform) widget.focusNode.unfocus();
  }

  void _action(ComposerAction a) {
    switch (a) {
      case ComposerAction.live:
        widget.onStartLive();
      case ComposerAction.send:
        _send(viaButton: true);
      case ComposerAction.stop:
        widget.onStop();
    }
  }

  void _notice(String message) {
    final n = widget.onNotice;
    if (n != null) {
      n(message);
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- the + tray ----------------------------------------------------------

  void _plus() => _trayOpen ? closeTray() : openTray();

  void openTray() {
    if (_trayOpen || !mounted) return;
    if (_effortOpen) closeEffort();
    FeedbackScope.haptic(context, Haptic.light);
    setState(() => _trayOpen = true);
    _trayPortal.show();
    if (Motion.reduced(context)) {
      _trayCtl.animateTo(
        1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.linear,
      );
    } else {
      _trayCtl.animateWith(
        SpringSimulation(Motion.sheet, _trayCtl.value, 1, 0),
      );
    }
  }

  void closeTray() {
    if (!_trayOpen) return;
    setState(() => _trayOpen = false);
    final reduced = Motion.reduced(context);
    _trayCtl.animateBack(
      0,
      duration: Duration(milliseconds: reduced ? 120 : 160),
      curve: reduced ? Curves.linear : Motion.exit,
    );
  }

  void _onTrayStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed && !_trayOpen && _trayPortal.isShowing) {
      _trayPortal.hide();
    }
  }

  Future<void> _pick(AttachmentOrigin origin) async {
    closeTray();
    final c = widget.attachments;
    if (c == null || !_attachmentsOn) return;
    final notices = await c.pick(origin);
    if (!mounted) return;
    for (final n in notices) {
      _notice(n);
    }
  }

  void _deepThink(bool on) {
    FeedbackScope.haptic(context, Haptic.selection);
    if (!on) {
      widget.onEffort(_beforeHigh ?? ReplyEffort.medium);
    } else {
      if (widget.effort != ReplyEffort.high) _beforeHigh = widget.effort;
      widget.onEffort(ReplyEffort.high);
    }
  }

  Widget _trayOverlay(BuildContext context) {
    final mq = MediaQuery.of(context);
    final pill = _pillKey.currentContext?.findRenderObject() as RenderBox?;
    final joined = !widget.live;
    var maxH = double.infinity;
    var width = 0.0;
    if (pill != null && pill.hasSize) {
      width = pill.size.width;
      final top = pill.localToGlobal(Offset.zero).dy;
      maxH = math.max(160.0, top - mq.padding.top - Sp.l - (joined ? 0 : 8));
    }
    final onSettings = widget.onVoiceSettings;
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _trayLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: Offset(0, joined ? 0 : -Sp.s),
        child: TapRegion(
          groupId: _trayGroup,
          onTapOutside: (_) => closeTray(),
          child: SizedBox(
            width: width,
            child: PlusTray(
              animation: _trayCtl,
              joined: joined,
              maxHeight: maxH,
              attachmentsSupported: _attachmentsOn,
              attachmentsRemaining: widget.attachments?.remaining,
              onPick: _pick,
              deepThink: widget.effort == ReplyEffort.high,
              onDeepThink: widget.effortEnabled ? _deepThink : null,
              readAloud: widget.readAloud,
              onReadAloud: widget.onReadAloud,
              settingsLabel: onSettings != null
                  ? 'Voice and speech settings'
                  : 'Settings',
              onSettings: () {
                closeTray();
                (onSettings ?? widget.onMore)();
              },
            ),
          ),
        ),
      ),
    );
  }

  // --- dictation -----------------------------------------------------------

  bool get _dictating =>
      _dictPhase == ComposerDictationPhase.starting ||
      _dictPhase == ComposerDictationPhase.listening ||
      _dictPhase == ComposerDictationPhase.stopping;

  /// The mic is shown and takes presses (text mode).
  bool get _showMic =>
      !kIsWeb &&
      widget.chatEnabled &&
      !widget.streaming &&
      (_dictating || _holdMode != null || (!_hasText && !_hasAttachments));

  bool get _micOn => mounted && !widget.live && _showMic;

  bool get _dictationReady =>
      widget.dictation != null && widget.dictation!.available;

  void _onMicDown(PointerDownEvent e) {
    if (_holdMode == HoldPanelMode.locked) {
      _press = _Press.sendTap;
    } else if (_holdMode != null) {
      _press = _Press.none;
    } else if (!_dictationReady) {
      _press = _Press.keyboard;
    } else if (_dictating) {
      _press = _Press.stopTap;
    } else {
      // Listening starts at once, so the first word is never lost; how the
      // press ends decides tap (into the field) or hold (send on release).
      _press = _Press.hold;
      _hold.down(e.position);
      _holdTimer?.cancel();
      _holdTimer = Timer(MicHoldMachine.holdDelay, () {
        if (mounted && _press == _Press.hold) _apply(_hold.holdElapsed());
      });
      unawaited(_beginDictation());
    }
    setState(() => _micDown = true);
  }

  void _onMicMove(PointerMoveEvent e) {
    if (_press != _Press.hold) return;
    final before = _hold.offset;
    final outcome = _hold.move(e.position);
    if (outcome != null) {
      _apply(outcome);
    } else if (_holdMode != null && before != _hold.offset) {
      setState(() {});
    }
  }

  void _onMicUp(PointerUpEvent e) {
    final press = _press;
    _press = _Press.none;
    _holdTimer?.cancel();
    setState(() => _micDown = false);
    switch (press) {
      case _Press.keyboard || _Press.stopTap:
        unawaited(_mic());
      case _Press.sendTap:
        unawaited(_holdSend());
      case _Press.hold:
        _apply(_hold.up());
      case _Press.none:
        break;
    }
  }

  void _onMicCancel() {
    final press = _press;
    _press = _Press.none;
    _holdTimer?.cancel();
    if (mounted) setState(() => _micDown = false);
    if (press == _Press.hold) _apply(_hold.pointerCancelled());
  }

  void _apply(MicHoldOutcome? outcome) {
    if (!mounted) return;
    final d = widget.dictation;
    if ((outcome == MicHoldOutcome.holdStarted ||
            outcome == MicHoldOutcome.lock) &&
        _holdMode == null &&
        !_dictating) {
      // Dictation could not start (no permission…): the press is over.
      _hold.reset();
      _press = _Press.none;
      return;
    }
    switch (outcome) {
      case null:
        break;
      case MicHoldOutcome.tap:
        // Tap to dictate, as before: the words go into the field.
        break;
      case MicHoldOutcome.holdStarted:
        _showHold(HoldPanelMode.holding);
      case MicHoldOutcome.lock:
        if (_holdMode == null) _showHold(HoldPanelMode.locked);
        FeedbackScope.haptic(context, Haptic.selection);
        _holdMode = HoldPanelMode.locked;
        _press = _Press.none;
      case MicHoldOutcome.cancel:
        FeedbackScope.haptic(context, Haptic.medium);
        _press = _Press.none;
        unawaited(_holdCancel());
        return;
      case MicHoldOutcome.send:
        unawaited(_holdSend());
        return;
    }
    if (d == null) return;
    setState(() {});
  }

  void _showHold(HoldPanelMode mode) {
    widget.dictation?.continuous = true;
    FeedbackScope.haptic(context, Haptic.medium);
    closeTray();
    _holdMode = mode;
    _holdPortal.show();
  }

  /// Hands-free from a screen reader's long press (no sliding needed).
  Future<void> _micHandsFree() async {
    if (!_micOn || !_dictationReady || _dictating || _holdMode != null) return;
    await _beginDictation(continuous: true);
    if (!mounted || !_dictating) return;
    _hold.reset();
    _showHold(HoldPanelMode.locked);
    setState(() {});
  }

  Future<void> _beginDictation({bool continuous = false}) async {
    final d = widget.dictation;
    if (d == null) return;
    closeTray();
    final text = widget.controller.text;
    _dictBase = text;
    _dictSep = text.isEmpty || RegExp(r'\s$').hasMatch(text) ? '' : ' ';
    FeedbackScope.haptic(context, Haptic.light);
    await d.start(continuous: continuous);
  }

  /// Released, or Send in hands-free: stop, then send the final words.
  Future<void> _holdSend() async {
    final d = widget.dictation;
    _hold.reset();
    if (d == null || !_dictating) {
      // Dictation already ended by itself: what reached the field goes.
      _endHold();
      if (_hasText) _send();
      setState(() {});
      return;
    }
    FeedbackScope.haptic(context, Haptic.light);
    setState(() {
      _holdMode = HoldPanelMode.sending;
      _sendWhenDone = true;
    });
    await d.stop();
  }

  Future<void> _holdCancel() async {
    _endHold();
    setState(() {});
    await _cancelDictation();
  }

  /// Hides the hold panel and forgets the press.
  void _endHold() {
    _holdTimer?.cancel();
    _hold.reset();
    _press = _Press.none;
    _holdMode = null;
    _sendWhenDone = false;
    if (_holdPortal.isShowing) _holdPortal.hide();
  }

  Future<void> _mic() async {
    final d = widget.dictation;
    if (d == null || !d.available) {
      // The keyboard's own voice input does the dictation.
      widget.focusNode.requestFocus();
      return;
    }
    if (_dictating) {
      // The selection click comes with the change to idle.
      await d.stop();
      return;
    }
    closeTray();
    final text = widget.controller.text;
    _dictBase = text;
    _dictSep = text.isEmpty || RegExp(r'\s$').hasMatch(text) ? '' : ' ';
    FeedbackScope.haptic(context, Haptic.light);
    await d.start();
  }

  Future<void> _cancelDictation() async {
    final d = widget.dictation;
    final base = _dictBase;
    _dictBase = null;
    _setPending(null);
    if (base != null) _setText(base);
    await d?.cancel();
  }

  void _setText(String text) {
    final capped = text.length > kMaxTaskChars
        ? text.substring(0, kMaxTaskChars)
        : text;
    widget.controller.value = TextEditingValue(
      text: capped,
      selection: TextSelection.collapsed(offset: capped.length),
    );
  }

  void _setPending(TextRange? r) {
    final c = widget.controller;
    if (c is ComposerTextController) {
      c.setPending(
        r,
        color: r == null ? null : HermesTokens.of(context).textMuted,
      );
    }
  }

  void _onDictation() {
    final d = widget.dictation;
    if (d == null || !mounted) return;
    final was = _dictPhase;
    _dictPhase = d.phase;
    final base = _dictBase;
    if (base != null) {
      final words =
          (d.phase == ComposerDictationPhase.idle ? d.finalText : null) ??
          d.partial;
      if (words.isNotEmpty) {
        final prefix = '$base$_dictSep';
        _setText('$prefix$words');
        final end = widget.controller.text.length;
        final stable = words.startsWith(d.stablePrefix)
            ? d.stablePrefix.length
            : 0;
        var from = math.min(prefix.length + stable, end);
        // Skip the space that joins the final and the unstable words.
        final t = widget.controller.text;
        while (from < end && t.codeUnitAt(from) == 0x20) {
          from++;
        }
        _setPending(
          d.phase == ComposerDictationPhase.idle || from >= end
              ? null
              : TextRange(start: from, end: end),
        );
      }
    }
    if (d.phase == ComposerDictationPhase.idle) {
      _setPending(null);
      final sending = _sendWhenDone;
      final holding = _holdMode != null;
      if (was != ComposerDictationPhase.idle &&
          d.error == null &&
          !sending &&
          !holding) {
        FeedbackScope.haptic(context, Haptic.selection);
      }
      _dictBase = null;
      final err = d.error;
      final heard = d.finalText != null;
      if (err != null || heard) {
        if (err != null) _dictationError(err);
        d.acknowledge();
      }
      if (sending || (holding && was != ComposerDictationPhase.idle)) {
        _endHold();
        if (sending && err == null) {
          if (!heard || !_hasText) {
            _notice("Didn't catch that. Nothing was sent.");
          } else if (_canSend) {
            _send();
          } else {
            _notice('Not sent yet. Your words are in the message box.');
          }
        }
      }
    }
    setState(() {});
  }

  void _dictationError(ComposerDictationError e) {
    switch (e.kind) {
      case ComposerDictationErrorKind.noMatch:
        _notice("Couldn't hear that");
      case ComposerDictationErrorKind.permissionDenied:
        _notice('Hermes needs microphone access to dictate');
      case ComposerDictationErrorKind.permissionBlocked:
        _notice(
          'Microphone access is off. Allow it in Settings › Apps › Hermes.',
        );
      case ComposerDictationErrorKind.unavailable:
        // No recogniser: the keyboard's voice key still works.
        widget.focusNode.requestFocus();
      case ComposerDictationErrorKind.other:
        _notice(e.message ?? "Dictation didn't work. Try again.");
    }
  }

  Widget _holdOverlay(BuildContext context) {
    final mode = _holdMode;
    final d = widget.dictation;
    if (mode == null || d == null) return const SizedBox.shrink();
    final pill = _pillKey.currentContext?.findRenderObject() as RenderBox?;
    final width = pill != null && pill.hasSize ? pill.size.width : 0.0;
    final panel = DictationHoldPanel(
      dictation: d,
      mode: mode,
      cancelProgress: _hold.cancelProgress,
      lockProgress: _hold.lockProgress,
      onCancel: () => unawaited(_holdCancel()),
      onSend: () => unawaited(_holdSend()),
    );
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _trayLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -Sp.s),
        // Taps on its buttons are not taps outside the field: the keyboard
        // stays as it was.
        child: TextFieldTapRegion(
          child: SizedBox(
            width: width,
            child: Motion.reduced(context)
                ? panel
                : TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 220),
                    curve: Motion.emphasizedDecel,
                    builder: (context, v, child) => Opacity(
                      opacity: v,
                      // Its buttons are there for screen readers from the
                      // first frame.
                      alwaysIncludeSemantics: true,
                      child: Transform.translate(
                        offset: Offset(0, 16 * (1 - v)),
                        child: child,
                      ),
                    ),
                    child: panel,
                  ),
          ),
        ),
      ),
    );
  }

  void openEffort() {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final chip = _gaugeKey.currentContext?.findRenderObject() as RenderBox?;
    if (stack != null && chip != null) {
      _gaugeRect = chip.localToGlobal(Offset.zero, ancestor: stack) & chip.size;
    }
    setState(() => _effortOpen = true);
    _effortCtl.duration = Motion.of(context, const Duration(milliseconds: 260));
    _effortCtl.forward(from: 0);
  }

  void closeEffort() {
    if (!_effortOpen) return;
    _effortCtl.reverseDuration = Motion.of(
      context,
      const Duration(milliseconds: 220),
    );
    _effortCtl.reverse().whenComplete(() {
      if (mounted) setState(() => _effortOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    final bottom = keyboard > 0
        ? keyboard + Sp.s
        : mq.viewPadding.bottom + Sp.composerBottom;
    final big = mq.textScaler.scale(10) / 10 >= 1.6;
    return PopScope(
      canPop: !_effortOpen && !_trayOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_trayOpen) {
          closeTray();
        } else {
          closeEffort();
        }
      },
      child: OverlayPortal(
        controller: _trayPortal,
        overlayChildBuilder: _trayOverlay,
        child: OverlayPortal(
          controller: _holdPortal,
          overlayChildBuilder: _holdOverlay,
          child: Padding(
            padding: EdgeInsets.fromLTRB(Sp.controls, 0, Sp.controls, bottom),
            child: LayoutBuilder(
              builder: (context, box) => AnimatedBuilder(
                animation: Listenable.merge([_live, _effortCtl, _trayCtl]),
                builder: (context, _) => _layout(context, box.maxWidth, big),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _iv(double from, double to, Curve c) =>
      Interval(from / _enterMs, to / _enterMs, curve: c).transform(_live.value);

  Widget _layout(BuildContext context, double w, bool big) {
    final t = HermesTokens.of(context);
    final reduced = Motion.reduced(context);
    final lt = _live.value;
    final tPill = reduced ? lt : _iv(80, 320, Motion.standard);
    final tMute = reduced ? lt : _iv(80, 280, Motion.pop);
    final tEnd = reduced ? lt : _iv(120, 320, Motion.pop);
    const c = Sz.liveControl, g = Sz.liveGap;
    final liveRowPill = big ? w : w - 2 * c - 2 * g;
    final pillW = w + (liveRowPill - w) * tPill;

    final pill = SizedBox(
      key: _pillKey,
      width: pillW,
      child: CompositedTransformTarget(
        link: _trayLink,
        child: _Pill(state: this, t: tPill),
      ),
    );
    Widget control(double v, Widget child) => v <= 0.001
        ? const SizedBox(width: c, height: c)
        : Opacity(
            opacity: v.clamp(0.0, 1.0),
            child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
          );
    // A failed call has no microphone to mute and no session to type into.
    final failed = widget.live && widget.callFailed;
    Widget gone(Widget child) => IgnorePointer(
      ignoring: failed,
      child: ExcludeSemantics(
        excluding: failed,
        child: AnimatedOpacity(
          opacity: failed ? 0 : 1,
          duration: Motion.of(context, const Duration(milliseconds: 160)),
          child: child,
        ),
      ),
    );
    final mute = gone(
      control(tMute, _MuteButton(muted: widget.muted, onTap: _mute)),
    );
    final end = control(
      tEnd,
      SolidRoundButton(
        label: 'End live voice',
        tooltip: 'End live voice (Esc)',
        color: t.closeFill,
        onPressed: widget.live ? widget.onEnd : null,
        child: Icon(Icons.close_rounded, color: t.onClose, size: 24),
      ),
    );
    final controlsVisible = lt > 0.001;

    Widget row;
    if (big) {
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          gone(pill),
          if (controlsVisible) ...[
            SizedBox(height: g * lt),
            ClipRect(
              child: Align(
                alignment: Alignment.topRight,
                heightFactor: lt,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    mute,
                    const SizedBox(width: g),
                    end,
                  ],
                ),
              ),
            ),
          ],
        ],
      );
    } else {
      row = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomLeft,
        children: [
          Align(alignment: Alignment.bottomLeft, child: gone(pill)),
          if (controlsVisible) ...[
            Positioned(right: c + g, bottom: 0, child: mute),
            Positioned(right: 0, bottom: 0, child: end),
          ],
        ],
      );
    }
    row = IgnorePointer(
      ignoring: _effortOpen,
      child: FadeTransition(
        opacity: ReverseAnimation(
          CurvedAnimation(
            parent: _effortCtl,
            curve: const Interval(0, 120 / 260),
          ),
        ),
        child: row,
      ),
    );
    if (!_effortOpen) {
      return SizedBox(key: _stackKey, width: w, child: row);
    }
    return Stack(
      key: _stackKey,
      clipBehavior: Clip.none,
      children: [
        SizedBox(width: w, child: row),
        _effortLayer(w),
      ],
    );
  }

  void _mute() {
    FeedbackScope.haptic(context, Haptic.selection);
    widget.onMute();
  }

  Widget _effortLayer(double w) {
    final trackW = math.min(Sz.effortTrack(w + 2 * Sp.controls), w);
    final full = Rect.fromLTWH((w - trackW) / 2, 0, trackW, Sz.effortTrackH);
    final from = _gaugeRect ?? full;
    final grow = Motion.emphasizedDecel.transform(_effortCtl.value);
    final rect = Rect.lerp(from, full, grow)!;
    final settled = _effortCtl.value >= 0.999 || Motion.reduced(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: TapRegion(
        onTapOutside: (_) => closeEffort(),
        child: SizedBox(
          height: Sz.effortTrackH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (!settled)
                Positioned.fromRect(
                  rect: rect,
                  child: const Glass(child: SizedBox.expand()),
                ),
              Positioned(
                left: full.left,
                width: full.width,
                bottom: 0,
                child: Opacity(
                  opacity: settled
                      ? 1
                      : const Interval(
                          100 / 260,
                          1,
                        ).transform(_effortCtl.value),
                  child: EffortSlider(
                    value: widget.effort,
                    width: trackW,
                    onChanged: widget.onEffort,
                    onDismiss: closeEffort,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pill: `surface` in text mode, glass in live mode.
class _Pill extends StatelessWidget {
  const _Pill({required this.state, required this.t});
  final ComposerState state;
  final double t;

  Composer get w => state.widget;

  @override
  Widget build(BuildContext context) {
    final tok = HermesTokens.of(context);
    final live = t >= 0.5;
    final fill = Color.lerp(tok.surface, tok.glassFallback, t)!;
    final atts = state._attachmentsOn ? w.attachments!.items : const [];
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Sz.composerMin),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _leading(context),
          Expanded(child: _field(context, live)),
          _trailing(context, live),
        ],
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: atts.isEmpty || live
          ? row
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Sp.xs),
                  child: AttachmentStrip(
                    items: [...atts.cast<StagedAttachment>()],
                    onRemove: w.attachments!.remove,
                    onRetry: w.attachments!.retry,
                  ),
                ),
                row,
              ],
            ),
    );
    // A zero-length AnimatedSize asserts when its child resizes, so
    // reduced motion skips it.
    final body = Motion.reduced(context)
        ? content
        : AnimatedSize(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: content,
          );
    if (t >= 1) return RepaintBoundary(child: Glass(child: body));
    // In text mode an open tray joins the pill: its top corners square off.
    const r = Sz.composerMin / 2;
    final tray = live ? 0.0 : state._trayCtl.value.clamp(0.0, 1.0);
    final top = Radius.circular(r * (1 - tray));
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: top,
              topRight: top,
              bottomLeft: const Radius.circular(r),
              bottomRight: const Radius.circular(r),
            ),
          ),
        ),
        child: body,
      ),
    );
  }

  /// + (rotating to × while the tray is open), or × to cancel dictation.
  Widget _leading(BuildContext context) {
    if (state._dictating) {
      return _iconButton(
        context,
        label: 'Cancel dictation',
        icon: Icons.close_rounded,
        onTap: state._cancelDictation,
      );
    }
    final open = state._trayOpen;
    final turn = state._trayCtl.value.clamp(0.0, 1.0);
    return TapRegion(
      groupId: state._trayGroup,
      child: _iconButton(
        context,
        label: open ? 'Close add menu' : 'Add',
        icon: Icons.add_rounded,
        onTap: state._plus,
        rotation: turn * math.pi / 4,
        expanded: open,
      ),
    );
  }

  Widget _iconButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    Key? key,
    double rotation = 0,
    bool? expanded,
  }) {
    final tok = HermesTokens.of(context);
    Widget glyph = Icon(icon, size: 22, color: tok.text);
    if (rotation != 0) glyph = Transform.rotate(angle: rotation, child: glyph);
    return SizedBox(
      key: key,
      height: Sz.composerMin,
      child: Center(
        child: Semantics(
          button: true,
          label: label,
          expanded: expanded,
          excludeSemantics: true,
          onTap: onTap,
          child: FocusRing(
            shape: const CircleBorder(),
            onActivate: onTap,
            child: InkResponse(
              onTap: onTap,
              radius: 22,
              child: SizedBox.square(dimension: Sz.hit, child: glyph),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(BuildContext context, bool live) {
    final tok = HermesTokens.of(context);
    if (!w.chatEnabled) {
      return GestureDetector(
        onTap: live || !w.liveAvailable ? null : w.onStartLive,
        child: Container(
          height: Sz.composerMin,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            live ? 'Live voice' : 'Talk to ${Brand.assistantName}',
            style: tok.body.copyWith(color: tok.textFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    final field = TextField(
      controller: w.controller,
      focusNode: w.focusNode,
      minLines: 1,
      maxLines: live ? 3 : 6,
      keyboardType: TextInputType.multiline,
      textInputAction: state._desktopKeys
          ? TextInputAction.send
          : TextInputAction.newline,
      textCapitalization: TextCapitalization.sentences,
      style: tok.body,
      cursorColor: tok.accent,
      maxLength: kMaxTaskChars,
      maxLengthEnforcement: MaxLengthEnforcement.enforced,
      buildCounter:
          (context, {required currentLength, required isFocused, maxLength}) =>
              currentLength < 7000
              ? null
              : Text(
                  '$currentLength / $maxLength',
                  style: tok.label.copyWith(
                    color: currentLength >= kMaxTaskChars
                        ? tok.danger
                        : tok.textMuted,
                  ),
                ),
      decoration: InputDecoration(
        // The name comes from the Semantics label below (it stays while
        // text is typed); the visible hint is not read a second time.
        hint: ExcludeSemantics(
          child: Text(
            state._dictating ? 'Listening…' : 'Ask ${Brand.assistantName}',
            style: tok.body.copyWith(color: tok.textFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        isDense: true,
        contentPadding: const EdgeInsets.fromLTRB(4, 13, 4, 13),
      ),
      onSubmitted: state._desktopKeys ? (_) => state._send() : null,
    );
    // A hint is no name: it goes when text is typed (§8.4).
    final named = Semantics(label: 'Ask ${Brand.assistantName}', child: field);
    if (!state._desktopKeys) return named;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): state._send,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): state._send,
      },
      child: named,
    );
  }

  /// The mic: idle, tap-dictating, or held (press and hold). One gesture
  /// detector stays across the three so a press survives the change.
  Widget _micSlot(BuildContext context) {
    final mode = state._holdMode;
    final d = w.dictation;
    final reduced = Motion.reduced(context);
    final Widget visual;
    if (mode != null && d != null) {
      final locked = mode == HoldPanelMode.locked;
      visual = Semantics(
        key: const ValueKey('mic-held'),
        button: locked,
        label: locked ? 'Send recording' : 'Recording',
        onTap: locked ? () => unawaited(state._holdSend()) : null,
        excludeSemantics: true,
        child: SizedBox(
          width: Sz.hit,
          height: Sz.composerMin,
          child: Center(
            child: HeldMic(
              dictation: d,
              offset: state._hold.offset,
              cancelProgress: state._hold.cancelProgress,
              mode: mode,
            ),
          ),
        ),
      );
    } else if (state._dictating && d != null) {
      visual = SizedBox(
        key: const ValueKey('mic-listening'),
        height: Sz.composerMin,
        child: Center(
          child: DictationMicButton(dictation: d, onTap: state._mic),
        ),
      );
    } else {
      visual = KeyedSubtree(
        key: const ValueKey('mic-idle'),
        child: _idleMic(context),
      );
    }
    return RawGestureDetector(
      gestures: state._micGestures,
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      child: AnimatedSwitcher(
        duration: Motion.of(context, const Duration(milliseconds: 180)),
        switchInCurve: Motion.standard,
        switchOutCurve: Motion.standard,
        // Only the incoming mic is named for screen readers, and from its
        // first frame.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          children: [
            for (final p in previous) ExcludeSemantics(child: p),
            ?current,
          ],
        ),
        transitionBuilder: (child, a) => reduced
            ? FadeTransition(
                opacity: a,
                alwaysIncludeSemantics: true,
                child: child,
              )
            : FadeTransition(
                opacity: a,
                alwaysIncludeSemantics: true,
                child: ScaleTransition(
                  scale: Tween<double>(
                    begin: 0.7,
                    end: 1,
                  ).animate(CurvedAnimation(parent: a, curve: Motion.pop)),
                  child: child,
                ),
              ),
        child: visual,
      ),
    );
  }

  Widget _idleMic(BuildContext context) {
    final tok = HermesTokens.of(context);
    final ready = state._dictationReady;
    return SizedBox(
      height: Sz.composerMin,
      child: Center(
        child: Semantics(
          button: true,
          label: 'Dictate',
          hint: ready ? 'Hold to talk and send' : null,
          excludeSemantics: true,
          onTap: state._mic,
          // A screen reader cannot slide: long press records hands-free,
          // with Cancel and Send buttons.
          onLongPress: ready ? () => unawaited(state._micHandsFree()) : null,
          child: Tooltip(
            message: ready ? 'Dictate · hold to talk and send' : 'Dictate',
            child: FocusRing(
              shape: const CircleBorder(),
              onActivate: state._mic,
              child: AnimatedScale(
                scale: state._micDown && !Motion.reduced(context) ? 0.86 : 1,
                duration: const Duration(milliseconds: 120),
                curve: Motion.standard,
                child: SizedBox.square(
                  dimension: Sz.hit,
                  child: Icon(
                    Icons.mic_none_rounded,
                    size: 22,
                    color: tok.text,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _trailing(BuildContext context, bool live) {
    final action = composerActionFor(
      hasText: w.chatEnabled && (state._hasText || state._hasAttachments),
      streaming: w.streaming,
    );
    Widget child;
    if (live && w.chatEnabled && state._hasText && !w.streaming) {
      // Typing in live mode: Send replaces the effort gauge until the text
      // goes (Enter still sends on a hardware keyboard).
      child = SizedBox(
        key: const ValueKey('live-send'),
        height: Sz.composerMin,
        child: Center(
          child: ComposerActionButton(
            action: ComposerAction.send,
            enabled: state._canSend,
            onPressed: () => state._send(viaButton: true),
          ),
        ),
      );
    } else if (live) {
      child = w.effortEnabled
          ? KeyedSubtree(
              key: const ValueKey('gauge'),
              child: _Gauge(
                key: state._gaugeKey,
                effort: w.effort,
                onTap: state.openEffort,
                onChange: w.onEffort,
              ),
            )
          : const SizedBox(key: ValueKey('none'), width: 4);
    } else {
      final showMic = state._showMic;
      child = Row(
        key: const ValueKey('text'),
        mainAxisSize: MainAxisSize.min,
        children: [
          _MaybeAnimatedSize(
            duration: const Duration(milliseconds: 140),
            child: AnimatedOpacity(
              duration: Motion.of(context, const Duration(milliseconds: 140)),
              opacity: showMic ? 1 : 0,
              child: !showMic
                  ? const SizedBox(height: Sz.composerMin)
                  : _micSlot(context),
            ),
          ),
          SizedBox(
            height: Sz.composerMin,
            child: Center(
              child: KeyedSubtree(
                key: w.actionKey,
                child: ComposerActionButton(
                  action: action,
                  enabled: switch (action) {
                    ComposerAction.live => w.liveAvailable,
                    ComposerAction.send => state._canSend,
                    ComposerAction.stop => true,
                  },
                  onPressed: () => state._action(action),
                ),
              ),
            ),
          ),
        ],
      );
    }
    // Part of the field's tap region: clicking Send (or the mic) on a
    // desktop is not a tap outside the field, so its focus stays. Phones
    // close the keyboard explicitly after a Send tap (see _send).
    return TextFieldTapRegion(
      child: AnimatedSwitcher(
        duration: Motion.of(context, const Duration(milliseconds: 160)),
        switchInCurve: Motion.standard,
        switchOutCurve: Motion.standard,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerRight,
          children: [...previous, ?current],
        ),
        child: child,
      ),
    );
  }
}

/// The 32 dp effort gauge chip in the live pill (§5.6, §8.4).
class _Gauge extends StatelessWidget {
  const _Gauge({
    super.key,
    required this.effort,
    required this.onTap,
    required this.onChange,
  });

  final ReplyEffort effort;
  final VoidCallback onTap;
  final ValueChanged<ReplyEffort> onChange;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final i = effort.index;
    return Semantics(
      button: true,
      label: 'Reply effort: ${effort.label}',
      value: effort.label,
      excludeSemantics: true,
      onTap: onTap,
      increasedValue: i < 2 ? ReplyEffort.values[i + 1].label : null,
      decreasedValue: i > 0 ? ReplyEffort.values[i - 1].label : null,
      onIncrease: i < 2 ? () => onChange(ReplyEffort.values[i + 1]) : null,
      onDecrease: i > 0 ? () => onChange(ReplyEffort.values[i - 1]) : null,
      child: FocusRing(
        shape: const CircleBorder(),
        onActivate: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: Sz.hit,
            height: Sz.composerMin,
            child: Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: t.surfaceHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.speed_rounded, size: 18, color: t.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 52 dp mute circle: glass when live, `closeFill` with `mic_off` when
/// muted (§5.6).
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return GlassButton(
      label: muted ? 'Unmute microphone' : 'Mute microphone',
      tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
      toggled: muted,
      size: Sz.liveControl,
      fill: muted ? t.closeFill : null,
      onPressed: onTap,
      child: AnimatedSwitcher(
        duration: Motion.of(context, const Duration(milliseconds: 160)),
        child: Icon(
          muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
          key: ValueKey(muted),
          size: 24,
          color: muted ? t.onClose : t.text,
        ),
      ),
    );
  }
}

/// [AnimatedSize], or just [child] with reduced motion (a zero-length
/// AnimatedSize asserts when its child resizes).
class _MaybeAnimatedSize extends StatelessWidget {
  const _MaybeAnimatedSize({required this.duration, required this.child});
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) => Motion.reduced(context)
      ? child
      : AnimatedSize(duration: duration, child: child);
}

/// What the press that is on the mic will do when it ends.
enum _Press {
  none,

  /// No in-app dictation: a tap focuses the field for the keyboard's mic.
  keyboard,

  /// Tap-dictation is running: a tap stops it.
  stopTap,

  /// Hands-free: a tap on the mic sends.
  sendTap,

  /// Idle: tap or hold ([MicHoldMachine]).
  hold,
}
