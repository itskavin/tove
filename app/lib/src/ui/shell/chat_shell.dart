import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../attachments/attachments.dart';
import '../../background/background.dart';
import '../../call/call_controller.dart';
import '../../call/models.dart' show TaskStatus;
import '../../chat/chat.dart';
import '../../notify/notify.dart';
import '../../platform/app_links.dart';
import '../../platform/device.dart';
import '../../settings/settings.dart';
import '../../speech/speech.dart';
import '../common/glass.dart';
import '../common/glyphs.dart';
import '../common/popover.dart';
import '../common/size_reporter.dart';
import '../common/toast.dart';
import '../composer/composer.dart';
import '../composer/speech_dictation.dart';
import '../interactive/interactive.dart';
import '../drawer/chat_drawer.dart';
import '../feedback.dart';
import '../live/live_overlay.dart';
import '../markdown/hermes_markdown.dart'
    show BridgeImageLoader, MarkdownImageLoader, MarkdownImageScope;
import '../live/live_settings_sheet.dart';
import '../settings/profile_page.dart';
import '../settings_screen.dart';
import '../tasks/tasks_panel.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../markdown/email_card.dart';
import 'drawer_swipe.dart';
import 'edge_feather.dart';
import 'header_pill.dart';
import 'live_swipe.dart';
import 'read_aloud_player.dart';
import 'sidebar_rail.dart';
import '../thread/follow_scroll.dart';
import '../thread/message_actions.dart';
import '../thread/messages.dart' show ThreadSelection;
import '../thread/starter_prompts.dart';
import '../thread/thread_view.dart';
import '../../brand.dart';

/// Holds the chat a live call should link to (read by [CallController]).
class LiveLink {
  String? conversationId;
}

ChatEffort chatEffort(ReplyEffort e) => switch (e) {
  ReplyEffort.instant => ChatEffort.instant,
  ReplyEffort.medium => ChatEffort.medium,
  ReplyEffort.high => ChatEffort.high,
};

/// The home screen (spec §2): thread, composer, push drawer (permanent
/// sidebar from 900 dp) and live mode as an overlay on the same thread.
class ChatShell extends StatefulWidget {
  const ChatShell({
    super.key,
    required this.settings,
    required this.call,
    required this.chat,
    required this.conversations,
    required this.liveLink,
    this.device,
    this.toasts,
    this.notifier,
    this.showBanner = true,
    this.push,
    this.notifyPrefs,
    this.notificationSink,
    this.instant,
    this.speech,
    this.starters,
    this.links,
  });

  final SettingsController settings;
  final CallController call;
  final ChatController chat;
  final ConversationsController conversations;
  final LiveLink liveLink;
  final DeviceServices? device;
  final ToastController? toasts;

  /// Reply notices (banner, notification taps) and push; null without them.
  final ReplyNotifier? notifier;

  /// Draw the reply banner in the shell (false when the app shows it above
  /// every route with ReplyBannerLayer).
  final bool showBanner;
  final PushRegistrar? push;
  final ReplyNotificationPrefs? notifyPrefs;
  final NotificationSink? notificationSink;

  /// Android's instant notifications (the app's own connection); null
  /// elsewhere.
  final InstantNotifications? instant;

  /// Dictation and read aloud; null when unavailable.
  final SpeechServices? speech;

  /// Picks the empty chat's suggestions (tests pass a seeded one).
  final StarterPrompts? starters;

  /// Widget and assistant links (Android); null elsewhere.
  final AppLinks? links;

  @override
  State<ChatShell> createState() => ChatShellState();
}

class ChatShellState extends State<ChatShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Drawer: open 300 ms emphasizedDecel, close 240 ms standard (§6.5).
  // Values above 1 are the rubber band past fully open (24 dp at most).
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    upperBound: 1.15,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
  );
  // Live mode: enter 420 ms, leave 340 ms (§6.4).
  late final AnimationController _live = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 340),
  );
  // The chat's Tasks panel (phones: from the right edge, after a leftward
  // swipe; wide: over the right side): the drawer's timings.
  late final AnimationController _tasks = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
  );
  final _tasksClose = FocusNode(debugLabel: 'close tasks');
  // New chat's entry: 180 ms fade and 8 dp rise of the thread layer.
  late final AnimationController _fresh = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final ToastController _toasts = widget.toasts ?? ToastController();
  // Draws dictation's partial words muted (composer README).
  final _text = ComposerTextController();
  final _focus = FocusNode(debugLabel: 'composer');
  final _shellFocus = FocusNode(debugLabel: 'shell');
  final _actionKey = GlobalKey();
  final _paneKey = GlobalKey();
  final _composerKey = GlobalKey<ComposerState>();
  final _overlayKey = GlobalKey<LiveOverlayState>();
  final _threadKey = GlobalKey<ThreadViewState>();
  final _scroll = FollowScrollController();
  final _searchRequests = ValueNotifier<int>(0);
  StreamSubscription<CallSummary>? _ended;
  StreamSubscription<String>? _opens;
  StreamSubscription<LaunchAction>? _launches;
  StreamSubscription<ReplyNotice>? _banners;
  final List<Timer> _taskChecks = [];

  /// Staged uploads; created when the bridge reports attachments.
  AttachmentController? _attachments;
  BridgeUploadClient? _uploader;

  /// "Search the web" for the next message only.
  bool _webSearch = false;
  late final SpeechComposerDictation? _dictation = widget.speech == null
      ? null
      : SpeechComposerDictation(widget.speech!.dictation);
  late final ReadAloud? _readAloudAdapter = widget.speech == null
      ? null
      : SpeechReadAloud(widget.speech!);

  /// For notifier.chatOpened and auto read-aloud.
  String? _shownChat;
  String? _streamingReply;

  bool _liveOpen = false;
  bool _callSeen = false;
  DateTime _liveSince = DateTime.now();
  Rect? _heroRect;
  CallPhase _lastPhase = CallPhase.idle;
  bool _dragging = false;
  double _drawerW = 300;

  // Sidebar swipe state (chat-rendering-v2 §4.2–§4.4).
  double _raw = 0;
  bool _dragStartedOpen = false;
  bool _crossed = false;
  bool _handoff = false;
  double? _backFrom;
  Timer? _scrollRefresh;

  // Pull up to live arms only over a thread at rest: not while the user
  // scrolls or flings it, nor for a moment after (live_swipe.dart).
  bool _userScrolling = false;
  Timer? _scrollSettle;

  /// The composer's laid-out height including its bottom gap; it grows with
  /// multi-line text, so the thread and the empty state keep clear of it.
  double? _composerExtent;

  /// Room between the end of the thread (the last reply's action row, or
  /// the text still streaming) and the composer's top, always: at rest,
  /// while streaming and with the keyboard open. The thread's bottom inset
  /// already holds 8 dp of it.
  static const double replyGap = 72;

  /// Checklist ticks per message (this device, plus synced settings).
  late final ChecklistStore _checklists = ChecklistStore(
    prefs: widget.settings.prefs,
    sync: widget.settings.sync,
  );

  // The empty chat's suggestions: a fresh set for every new chat.
  late final StarterPrompts _starterPicker =
      widget.starters ?? StarterPrompts();
  late List<StarterPrompt> _starters = _starterPicker.next();
  DateTime _startersShownAt = DateTime.now();
  RemoteSuggestions? _remoteSuggestions;
  bool _remoteTried = false;
  bool _emptyShown = true;

  // Swipe up to live (live_swipe.dart): upward travel of the drag being
  // followed, and the spring back after a release that did not open live.
  final _liveSwipe = ValueNotifier<double>(0);
  late final AnimationController _liveSwipeBack = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onLiveSwipeBack);
  double _liveSwipeFrom = 0;
  bool _liveSwipeCrossed = false;

  CallController get call => widget.call;
  ChatController get chat => widget.chat;
  AppFeedback? get _feedback => FeedbackScope.of(context);

  bool get liveOpen => _liveOpen;

  @override
  void initState() {
    super.initState();
    call.addListener(_onCall);
    chat.addListener(_onChat);
    _ended = call.ended.listen(_importCall);
    _drawer.addStatusListener((_) => setState(() {}));
    _tasks.addStatusListener(_onTasksStatus);
    WidgetsBinding.instance.addObserver(this);
    // Banner "View" and notification taps open their chat.
    _opens = widget.notifier?.opens.listen((id) => unawaited(openChat(id)));
    // A reply or live-call task saved to the chat on screen: show it.
    _banners = widget.notifier?.banners.listen((n) {
      if (n.conversationId != null &&
          n.conversationId == chat.currentConversationId) {
        unawaited(chat.refreshCurrent());
      }
    });
    widget.speech?.settings.addListener(_onSpeechSettings);
    widget.speech?.tts.addListener(_onTts);
    // A cold start from a notification tap (the app's own, or the
    // instant-notification service's).
    final sink = widget.notificationSink;
    if (sink != null) {
      unawaited(
        sink.launchConversation().then((id) {
          if (id != null && mounted) unawaited(openChat(id));
        }),
      );
    }
    final instant = widget.instant;
    if (instant != null) {
      unawaited(
        instant.launchChat().then((id) {
          if (id != null && mounted) unawaited(openChat(id));
        }),
      );
    }
    // Home-screen widgets and the assistant gesture (cold start: after the
    // first frame, so the composer and live mode have their layout).
    final links = widget.links;
    if (links != null) {
      _launches = links.actions.listen((a) => unawaited(handleLaunch(a)));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          links.initial().then((a) {
            if (a != null && mounted) unawaited(handleLaunch(a));
          }),
        );
      });
    }
    _syncAttachments();
  }

  /// A `tove://` link from a widget or the assistant gesture: back to the
  /// chat screen, then a new chat (with the keyboard up when asked), live
  /// mode in a fresh chat, or the given chat.
  Future<void> handleLaunch(LaunchAction a) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    switch (a) {
      case NewChatAction(:final keyboard):
        await newChat();
        if (keyboard && mounted && !_liveOpen) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_liveOpen) _focus.requestFocus();
          });
        }
      case OpenLive():
        if (_liveOpen || call.inCall) return;
        if (_drawerOpen) closeDrawer();
        if (!_tasks.isDismissed) closeTasks();
        if (!_isEmptyChat) {
          chat.newChat();
          _text.clear();
        }
        // A cold start: link the call to the chat once the bridge's
        // capabilities are known.
        if (!chat.capabilities.known) {
          try {
            await chat.refreshCapabilities();
          } catch (_) {}
          if (!mounted) return;
        }
        await startLive();
      case OpenChatAction(:final id):
        await openChat(id);
    }
  }

  void _onSpeechSettings() {
    if (mounted) setState(() {});
  }

  bool _playerShown = false;

  void _onTts() {
    final shown = widget.speech?.tts.value.isActive ?? false;
    if (shown != _playerShown && mounted) setState(() => _playerShown = shown);
  }

  /// Creates, updates or drops the attachment controller to match the
  /// bridge's capabilities (off while it reports `attachments: false`).
  void _syncAttachments() {
    final caps = chat.capabilities;
    if (!caps.attachments) return;
    final settings = widget.settings;
    final base = Uri.tryParse(settings.url);
    if (base == null) return;
    final ac = AttachmentCapabilities.fromJson(caps.raw);
    if (_attachments != null) {
      _attachments!.capabilities = ac;
      return;
    }
    _uploader = BridgeUploadClient(
      baseUrl: base,
      accessKey: settings.accessKey,
    );
    _attachments = AttachmentController(
      uploader: _uploader!,
      picker: SystemAttachmentPicker(),
      capabilities: ac,
      conversationId: () => chat.currentConversationId,
    );
  }

  /// Opens [id] from a notification or the banner.
  Future<void> openChat(String id) async {
    if (id == chat.currentConversationId) {
      if (_drawerOpen) closeDrawer();
      return;
    }
    await _select(id);
  }

  BridgeImageLoader? _images;

  /// Reply images load through the bridge's link preview, never from the
  /// image host directly; none while the bridge does not offer it.
  MarkdownImageLoader? get _imageLoader {
    if (chat.capabilities.raw['link_preview'] != true) return null;
    final base = Uri.tryParse(widget.settings.url);
    if (base == null) return null;
    return _images ??= BridgeImageLoader(
      baseUrl: base,
      accessKey: widget.settings.accessKey,
    );
  }

  @override
  void dispose() {
    _images?.close();
    WidgetsBinding.instance.removeObserver(this);
    _checklists.dispose();
    call.removeListener(_onCall);
    chat.removeListener(_onChat);
    unawaited(_ended?.cancel());
    unawaited(_opens?.cancel());
    unawaited(_launches?.cancel());
    unawaited(_banners?.cancel());
    for (final t in _taskChecks) {
      t.cancel();
    }
    widget.speech?.settings.removeListener(_onSpeechSettings);
    widget.speech?.tts.removeListener(_onTts);
    _attachments?.dispose();
    _scrollRefresh?.cancel();
    _scrollSettle?.cancel();
    unawaited(widget.device?.requestHighRefresh('scroll', false));
    _drawer.dispose();
    _tasks.dispose();
    _tasksClose.dispose();
    _railExpandFocus.dispose();
    _collapseFocus.dispose();
    _live.dispose();
    _fresh.dispose();
    if (widget.toasts == null) _toasts.dispose();
    _text.dispose();
    _focus.dispose();
    _shellFocus.dispose();
    _scroll.dispose();
    _searchRequests.dispose();
    _liveSwipe.dispose();
    _liveSwipeBack.dispose();
    _remoteSuggestions?.close();
    super.dispose();
  }

  // --- live mode -----------------------------------------------------------

  Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    final pane = _paneKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || pane == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: pane) & box.size;
  }

  Future<void> startLive() async {
    if (_liveOpen || call.inCall) return;
    if (!_tasks.isDismissed) closeTasks();
    _feedback?.haptic(Haptic.light);
    _composerKey.currentState?.closeEffort();
    final r = _rectOf(_actionKey);
    // The orb grows from the 40 dp glyph inside the action button.
    _heroRect = r == null
        ? null
        : Rect.fromCenter(center: r.center, width: 40, height: 40);
    setState(() {
      _liveOpen = true;
      _callSeen = false;
      _liveSince = DateTime.now();
    });
    // Read aloud pauses and dictation stops while the call has the audio.
    widget.speech?.liveModeActive = true;
    _live.duration = Motion.reduced(context)
        ? Motion.reducedDuration
        : const Duration(milliseconds: 420);
    unawaited(_live.forward());
    unawaited(widget.device?.requestHighRefresh('live', true));
    widget.liveLink.conversationId = await chat.conversationIdForLive();
    if (!mounted || !_liveOpen) return;
    await call.start();
  }

  Future<void> endLive() async {
    _feedback?.haptic(Haptic.medium);
    // Teardown starts at once; the animation never delays the hang-up.
    unawaited(call.end());
    _closeLive();
  }

  void _closeLive() {
    if (!_liveOpen) return;
    widget.speech?.liveModeActive = false;
    _live.reverseDuration = Motion.reduced(context)
        ? Motion.reducedDuration
        : const Duration(milliseconds: 340);
    _live.reverse().whenComplete(() {
      if (!mounted || call.inCall) return;
      setState(() => _liveOpen = false);
    });
    unawaited(widget.device?.requestHighRefresh('live', false));
    setState(() {});
  }

  void _onCall() {
    final phase = call.phase;
    if (phase != _lastPhase) {
      if (phase == CallPhase.live && _lastPhase == CallPhase.connecting) {
        _feedback?.haptic(Haptic.light);
        _feedback?.cue(Cue.connected);
      }
      if (_lastPhase == CallPhase.live && phase != CallPhase.live) {
        _feedback?.cue(Cue.ended);
      }
      if (phase == CallPhase.failed) _feedback?.haptic(Haptic.heavy);
      _lastPhase = phase;
    }
    if (call.inCall) {
      _callSeen = true;
      // A call started elsewhere (notification, shortcut): show live mode.
      if (!_liveOpen) {
        setState(() {
          _liveOpen = true;
          _liveSince = DateTime.now();
          _heroRect = null;
        });
        widget.speech?.liveModeActive = true;
        unawaited(_live.forward());
        unawaited(widget.device?.requestHighRefresh('live', true));
      }
    }
    if (_liveOpen && _callSeen && phase == CallPhase.idle) _closeLive();
    final n = call.notice;
    if (n != null && n != _lastNotice) {
      _toasts.show(n, kind: ToastKind.warning);
    }
    _lastNotice = n;
    // Rebuild only for what the shell shows (transcript chunks notify too).
    final sig = Object.hash(phase, call.muted, call.inCall, call.activeTasks);
    if (sig != _callSig && mounted) {
      _callSig = sig;
      setState(() {});
    }
  }

  String? _lastNotice;
  int? _callSig;
  int? _chatSig;

  void _onChat() {
    final e = chat.error;
    if (e != null) {
      final text = switch (e.kind) {
        ChatErrorKind.usageLimit =>
          'You have reached your usage limit. Try again later.',
        ChatErrorKind.loginExpired =>
          'The ${Brand.serverName}’s login has expired. It needs renewing on the '
              'server.',
        ChatErrorKind.unauthorized =>
          'The access key was rejected. Check it in Settings.',
        ChatErrorKind.busy =>
          '${Brand.assistantName} is busy with two replies. Try again soon.',
        ChatErrorKind.network => 'Couldn’t reach the ${Brand.serverName}.',
        _ => e.message,
      };
      _toasts.show(text, kind: ToastKind.error);
      if (e.kind == ChatErrorKind.usageLimit) _feedback?.haptic(Haptic.heavy);
      chat.clearError();
    }
    // The chat on screen changed: clear its banner and notification.
    final shown = chat.currentConversationId;
    if (shown != _shownChat) {
      _shownChat = shown;
      if (shown != null) widget.notifier?.chatOpened(shown);
    }
    // A reply finished in text mode: auto read-aloud, when it is on.
    final streamingId = chat.streamingMessage?.id;
    if (_streamingReply != null && streamingId == null && !_liveOpen) {
      final done = chat.messages.where((m) => m.isAssistant).lastOrNull;
      if (done != null &&
          done.text.isNotEmpty &&
          done.status == MessageStatus.done) {
        unawaited(
          widget.speech?.tts.onReplyFinished(
            done.id,
            hermesUiPlainText(done.text),
          ),
        );
      }
    }
    _streamingReply = streamingId;
    // Back on an empty new chat: a fresh set of suggestions.
    final empty = _isEmptyChat;
    if (empty && !_emptyShown) _refreshStarters();
    _emptyShown = empty;
    if (!_remoteTried && chat.capabilities.raw['suggestions'] == true) {
      _remoteTried = true;
      unawaited(_fetchRemoteStarters(_startersShownAt));
    }
    // Streaming text notifies ~30 times a second; the thread listens itself.
    final caps = chat.capabilities;
    if (caps.attachments != (_attachments != null)) _syncAttachments();
    final sig = Object.hash(
      chat.streaming,
      // The Tasks glyph's dot: on once the streaming reply calls a tool.
      chat.streaming && _workRunning,
      chat.title,
      chat.conversation?.pinned,
      chat.currentConversationId,
      caps.chat,
      caps.history,
      caps.effort,
      caps.known,
      caps.attachments,
      caps.webSearch,
      chat.reconnecting,
      chat.streamingElsewhere,
      chat.messages.isEmpty,
      chat.loading,
    );
    if (sig != _chatSig && mounted) {
      _chatSig = sig;
      setState(() {});
    }
  }

  // --- starter suggestions -------------------------------------------------

  bool get _isEmptyChat =>
      chat.messages.isEmpty && chat.conversation == null && !chat.loading;

  /// A new set for the empty chat (none of the last set comes back), and a
  /// fetch of the bridge's suggestions for this one or the next.
  void _refreshStarters() {
    _startersShownAt = DateTime.now();
    final next = _starterPicker.next();
    if (mounted) setState(() => _starters = next);
    if (chat.capabilities.raw['suggestions'] == true) {
      unawaited(_fetchRemoteStarters(_startersShownAt));
    }
  }

  /// `GET /api/suggestions` (bridges that report `suggestions: true`). It
  /// never blocks the empty chat: a set that arrives within 800 ms of the
  /// chat opening replaces the local one, later ones wait for the next chat.
  Future<void> _fetchRemoteStarters(DateTime shownAt) async {
    final base = Uri.tryParse(widget.settings.url);
    if (base == null) return;
    final r = _remoteSuggestions ??= RemoteSuggestions(
      baseUrl: base,
      accessKey: widget.settings.accessKey,
    );
    final got = await r.fetch();
    if (!mounted || got.isEmpty) return;
    _starterPicker.remote = got;
    final fresh =
        DateTime.now().difference(shownAt) < const Duration(milliseconds: 800);
    if (fresh && shownAt == _startersShownAt && _isEmptyChat) {
      setState(() => _starters = _starterPicker.next());
    }
  }

  // --- pull up to live ----------------------------------------------------

  /// How far a pull must go before release starts live (live_swipe.dart).
  double get _livePull =>
      LiveSwipeRecognizer.thresholdFor(MediaQuery.sizeOf(context).height);

  /// The user is scrolling or flinging the thread, or just stopped.
  bool get _threadMoving => _userScrolling || _scrollSettle != null;

  void _settleScroll() {
    _scrollSettle?.cancel();
    _scrollSettle = Timer(
      LiveSwipeRecognizer.settleAfterScroll,
      () => _scrollSettle = null,
    );
  }

  /// The thread shows its newest text (nothing left to scroll toward).
  bool get _threadAtEnd {
    if (chat.messages.isEmpty || !_scroll.hasClients) return true;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return true;
    // Within a line of the end counts (round 8): a reply that settled a few
    // dp short of it refused the swipe.
    return p.maxScrollExtent - p.pixels <= 32;
  }

  /// Where a pull up to live may start (live_swipe.dart): on the composer or
  /// just above it, only while the thread already rests at its end (not
  /// during or just after a scroll or fling); touch only; not when turned
  /// off in Settings, with the keyboard up, in live mode, with a panel open
  /// or inside the system's bottom gesture inset. A text selection blocks
  /// it only above the composer (round 8: a stray long press used to block
  /// it everywhere).
  bool _canLiveSwipe(PointerDownEvent e) => _liveSwipeAt(e) != null;

  /// Where [e] would start a swipe up to live: `true` on the composer,
  /// `false` in the zone above it, null where it cannot.
  bool? _liveSwipeAt(PointerDownEvent e) {
    if (!mounted || _liveOpen || call.inCall) return null;
    if (!widget.settings.pullToLive) return null;
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return null;
    }
    if (!_drawer.isDismissed || !_tasks.isDismissed || _dragging) return null;
    if (_composerKey.currentState?.effortOpen ?? false) return null;
    final mq = MediaQuery.of(context);
    if (mq.viewInsets.bottom > 0) return null;
    if (e.position.dy > mq.size.height - mq.systemGestureInsets.bottom) {
      return null;
    }
    final pane = _paneKey.currentContext?.findRenderObject() as RenderBox?;
    final composer = _rectOf(_composerKey);
    if (pane == null || composer == null) return null;
    final y = pane.globalToLocal(e.position).dy;
    if (y > composer.bottom) return null;
    if (y < composer.top - LiveSwipeRecognizer.zone) return null;
    if (_threadMoving || !_threadAtEnd) return null;
    if (y >= composer.top) return true;
    if (ThreadSelection.active.value) return null;
    return false;
  }

  // Swipe up to live, followed from raw pointer events after the composer's
  // text field won the arena (its long press: the "Paste" menu).
  int? _liveRaw;
  Offset _liveRawTravel = Offset.zero;
  bool _liveRawLost = false;
  bool _liveRawFollowing = false;
  VelocityTracker? _liveRawVelocity;

  bool _onLiveButton(Offset global) {
    if (_liveOpen || call.inCall) return false;
    final box = _actionKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  void _onLiveLost(int pointer) {
    if (pointer == _liveRaw) _liveRawLost = true;
  }

  void _beginLiveSwipe() {
    _liveSwipeBack.stop();
    _liveSwipe.value = 0;
    _liveSwipeCrossed = false;
    if (ThreadSelection.active.value) ThreadSelection.clearAll();
    ContextMenuController.removeAny();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _followLiveSwipe(double up) {
    final v = up.clamp(0.0, 400.0);
    _liveSwipe.value = v;
    final crossed = v >= _livePull;
    if (crossed && !_liveSwipeCrossed) {
      _feedback?.haptic(Haptic.selection);
    }
    _liveSwipeCrossed = crossed;
  }

  /// The finger lifted: live starts only past the threshold and when the
  /// finger was not flicking ([velocity] upward-positive dp/s). A flick also
  /// keeps the pull off for a moment, like a fling of the thread.
  void _endLiveSwipe(double velocity) {
    final open = liveSwipeShouldOpen(
      travel: _liveSwipe.value,
      threshold: _livePull,
      velocity: velocity,
    );
    if (velocity >= LiveSwipeRecognizer.maxReleaseVelocity) _settleScroll();
    _releaseLiveSwipe();
    if (open) unawaited(startLive());
  }

  late final _liveSwipeFactory =
      GestureRecognizerFactoryWithHandlers<LiveSwipeRecognizer>(
        () => LiveSwipeRecognizer(
          debugOwner: this,
          canStart: _canLiveSwipe,
          onLost: _onLiveLost,
        ),
        (r) => r
          ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = ((_) => _beginLiveSwipe())
          ..onUpdate = ((d) => _followLiveSwipe(_liveSwipe.value - d.delta.dy))
          ..onEnd = ((d) => _endLiveSwipe(-d.velocity.pixelsPerSecond.dy))
          ..onCancel = _releaseLiveSwipe,
      );

  /// The composer settles back: 220 ms, or at once with reduced motion.
  void _releaseLiveSwipe() {
    _liveSwipeCrossed = false;
    if (_liveSwipe.value == 0) return;
    if (!mounted || Motion.reduced(context)) {
      _liveSwipe.value = 0;
      return;
    }
    _liveSwipeFrom = _liveSwipe.value;
    _liveSwipeBack.forward(from: 0);
  }

  void _onLiveSwipeBack() {
    final v = Curves.easeOutCubic.transform(_liveSwipeBack.value);
    _liveSwipe.value = _liveSwipeFrom * (1 - v);
  }

  Future<void> _importCall(CallSummary s) async {
    final key = callKey(s.session);
    final turns = liveTurnsFromTranscript(s.transcript, key: key);
    final tasks = s.linked
        ? const <LiveTask>[]
        : liveTasksFromEntries(s.tasks, key: key);
    _watchUnfinishedTasks(s);
    if (turns.isEmpty && tasks.isEmpty) {
      // Nothing was said: the chat made for the call goes again, and an
      // existing chat is left exactly as it was (no icon change, no reorder).
      final id = s.conversationId;
      if (id != null && s.tasks.isEmpty) unawaited(chat.discardEmptyChat(id));
      return;
    }
    _threadKey.currentState?.staggerNext(turns.length + tasks.length);
    await chat.importLiveTranscript(
      turns,
      tasks: tasks,
      session: s.session,
      conversationId: s.conversationId,
    );
  }

  /// Tasks the call left running finish on the bridge and land in the linked
  /// chat. Without push nothing announces them, so re-read that chat a few
  /// times while it is on screen.
  void _watchUnfinishedTasks(CallSummary s) {
    final id = s.conversationId;
    if (id == null || !s.tasks.any((t) => t.status == TaskStatus.stopped)) {
      return;
    }
    // Bridges with `task_messages`: the tasks are already in the chat and
    // stream there (TaskStreams), and the events stream announces their end.
    if (chat.capabilities.taskMessages) return;
    for (final secs in const [20, 60, 150, 300]) {
      _taskChecks.add(
        Timer(Duration(seconds: secs), () {
          if (mounted && chat.currentConversationId == id) {
            unawaited(chat.refreshCurrent());
          }
        }),
      );
    }
  }

  // --- text ----------------------------------------------------------------

  /// Read aloud through the speech module; null hides the button.
  ReadAloud? get _readAloud => _readAloudAdapter;

  /// Email drafts go to Gmail or the default mail app (round 8).
  late final EmailComposer _email = _DeviceEmailComposer(widget.device);

  Future<void> _shareText(String text) async {
    final shared = await widget.device?.shareText(text) ?? false;
    if (shared || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    _toasts.show('Copied. Paste it to share.', kind: ToastKind.success);
  }

  void _notify(String text) => _toasts.show(text, kind: ToastKind.success);

  /// Sent attachments load from the bridge with the access key.
  ImageProvider? _attachmentImage(
    MessageAttachment a, {
    required bool preview,
  }) {
    final base = Uri.tryParse(widget.settings.url);
    if (base == null || !a.isImage) return null;
    final client = _uploader ??= BridgeUploadClient(
      baseUrl: base,
      accessKey: widget.settings.accessKey,
    );
    final path = preview && a.previewUrl != null
        ? a.previewUrl!
        : '/api/uploads/${Uri.encodeComponent(a.id)}';
    return NetworkImage(
      client.resolve(path).toString(),
      headers: client.authHeaders,
    );
  }

  void _copyFromUi(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _notify('Copied');
  }

  void _send(String text) => _submit(ComposerMessage(text: text));

  /// Sends the composer's message: text, uploaded attachments and the
  /// one-message "Search the web" flag.
  void _submit(ComposerMessage m) {
    _feedback?.haptic(Haptic.light);
    unawaited(
      chat.send(
        m.text,
        effort: chatEffort(widget.settings.effort),
        attachments: [
          for (final a in m.attachments)
            MessageAttachment(
              id: a.id,
              name: a.name,
              mime: a.mime,
              size: a.size,
              width: a.width,
              height: a.height,
              previewUrl: a.previewUrl,
            ),
        ],
        webSearch: m.webSearch,
      ),
    );
    if (_webSearch) setState(() => _webSearch = false);
    // The thread brings the new message up under the app bar itself.
  }

  /// §6.10: the highest refresh rate while the thread moves.
  bool _onThreadNotification(Notification n) {
    if (n is! ScrollNotification || n.depth != 0) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    // The user's own drag of the thread, its fling included (and a drag that
    // only overscrolls at the end), until it comes to rest; then a short
    // settle before pull up to live arms again. Programmatic scrolls (a
    // streaming reply following its end) do not count.
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScrolling = true;
      _scrollSettle?.cancel();
      _scrollSettle = null;
    } else if (n is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _settleScroll();
    }
    if (n is ScrollStartNotification) {
      _scrollRefresh?.cancel();
      unawaited(widget.device?.requestHighRefresh('scroll', true));
    } else if (n is ScrollEndNotification) {
      _scrollRefresh?.cancel();
      _scrollRefresh = Timer(const Duration(milliseconds: 1500), () {
        unawaited(widget.device?.requestHighRefresh('scroll', false));
      });
    }
    return false;
  }

  /// Android Back (predictive back on API 33+): close the effort slider (the
  /// composer does that itself), then the drawer, then leave live mode. Sheets
  /// and popovers are routes above this one, so the navigator closes them
  /// first. With none of these open, Back on Android minimises the app like
  /// Home (round 6): the task goes to the background and the chat, a reply in
  /// flight and the engine stay as they were.
  void handleBack() {
    if (_composerKey.currentState?.effortOpen ?? false) return;
    if (_tasksOpen) {
      closeTasks();
    } else if (_drawerOpen) {
      closeDrawer();
    } else if (_liveOpen) {
      unawaited(endLive());
    } else if (_minimiseOnBack) {
      unawaited(_minimise());
    }
  }

  /// Android keeps every Back at the root for [handleBack].
  bool get _minimiseOnBack => widget.device?.android ?? false;

  Future<void> _minimise() async {
    final done = await widget.device?.moveTaskToBack() ?? false;
    // An older build without the method: leave the app as before.
    if (!done) await SystemNavigator.pop();
  }

  /// Panel progress (0 closed, 1 open), for the gesture tests.
  @visibleForTesting
  double get drawerProgress => _drawer.value;
  @visibleForTesting
  double get tasksProgress => _tasks.value;
  @visibleForTesting
  double get drawerWidth => _drawerW;

  bool get _drawerOpen => !_wide && !_drawer.isDismissed;
  bool get _tasksOpen => !_tasks.isDismissed;

  /// Tool work runs in this chat now: the reply streaming here has called a
  /// tool, or a live-voice job of a call linked to it is active. A plain
  /// reply being written is not a task (user rule, 16 Nov 2026).
  bool get _workRunning => toolWorkRunning(chat: chat, call: call);

  void _onTasksStatus(AnimationStatus s) {
    if (!mounted) return;
    setState(() {});
    // Keyboard and screen-reader users land on the panel's close button,
    // and go back to the shell when it closes.
    if (s == AnimationStatus.completed) {
      _tasksClose.requestFocus();
    } else if (s == AnimationStatus.dismissed && _tasksClose.hasFocus) {
      _shellFocus.requestFocus();
    }
  }

  /// Opens the chat's Tasks panel.
  void openTasks() {
    if (_liveOpen) return;
    if (!_drawer.isDismissed && !_wide) closeDrawer();
    FocusManager.instance.primaryFocus?.unfocus();
    _tasks.duration = Motion.spatial(
      context,
      const Duration(milliseconds: 300),
    );
    _tasks.animateTo(
      1,
      curve: Motion.spatialCurve(context, Motion.emphasizedDecel),
    );
  }

  void closeTasks() {
    _tasks.reverseDuration = Motion.spatial(
      context,
      const Duration(milliseconds: 240),
    );
    _tasks.animateBack(0, curve: Motion.spatialCurve(context, Motion.standard));
  }

  void _onComposerSize(Size size) {
    if (_composerExtent == size.height) return;
    setState(() => _composerExtent = size.height);
  }

  // --- navigation ----------------------------------------------------------

  bool get _wide => MediaQuery.sizeOf(context).width >= Sz.wideLayout;

  void openDrawer() {
    if (_wide) return;
    if (!_tasks.isDismissed) {
      _tasks.stop();
      _tasks.value = 0;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _drawer.duration = Motion.spatial(
      context,
      const Duration(milliseconds: 300),
    );
    _drawer.animateTo(
      1,
      curve: Motion.spatialCurve(context, Motion.emphasizedDecel),
    );
  }

  void closeDrawer() {
    _drawer.reverseDuration = Motion.spatial(
      context,
      const Duration(milliseconds: 240),
    );
    _drawer.animateBack(
      0,
      curve: Motion.spatialCurve(context, Motion.standard),
    );
  }

  // --- sidebar swipe -------------------------------------------------------

  /// Where a swipe may start (§4.2): not in the system back-gesture insets,
  /// not on a horizontal scroller (it hands off at its start edge instead),
  /// a slider or other [DrawerSwipeExclusion], the focused composer, or while
  /// text is selected.
  bool _canSwipeFrom(PointerDownEvent e) {
    if (_wide || !mounted) return false;
    if (_drawer.value > 0) return true; // Open: a swipe anywhere closes.
    if (_tasks.value > 0) {
      // Open: a swipe closes it, except on a scroller or slider inside.
      final hit = swipeHitInfo(e.position, View.of(context).viewId);
      return !hit.excluded && !hit.horizontalScroller;
    }
    if (ThreadSelection.active.value) return false;
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final x = e.position.dx;
    if (x < insets.left || x > size.width - insets.right) return false;
    if (_focus.hasFocus) {
      final r = _rectOf(_composerKey);
      final pane = _paneKey.currentContext?.findRenderObject() as RenderBox?;
      if (r != null && pane != null) {
        final local = pane.globalToLocal(e.position);
        if (r.contains(local)) return false;
      }
    }
    final hit = swipeHitInfo(e.position, View.of(context).viewId);
    return !hit.excluded && !hit.horizontalScroller;
  }

  /// The drag being followed moves the Tasks panel, not the drawer.
  bool _swipeTasks = false;
  double _tasksRaw = 0;
  bool _tasksStartedOpen = false;

  /// Leftward drags open the chat's Tasks from the right edge. Not in live
  /// mode, which shows its work under the orb (Tasks does not open there).
  bool get _tasksSwipeAllowed => !_wide && !_liveOpen;

  /// The allowed sign of a new swipe's travel (see [DrawerSwipeRecognizer]):
  /// an open panel follows either way; with both closed, rightward opens
  /// the chat list and leftward Tasks (only rightward in live mode).
  int _swipeDirection() {
    if (_drawer.value > 0 || _tasks.value > 0) return 0;
    return _tasksSwipeAllowed ? 0 : 1;
  }

  /// Starts following an accepted swipe (user rule, 16 Nov 2026): an open
  /// panel follows any drag; with both closed, a rightward drag opens the
  /// chat list from the left and a leftward one this chat's Tasks from the
  /// right, each following the finger.
  void _beginSwipe(Offset travel) {
    // Alone in the gesture arena (an empty stretch of the chat) the swipe
    // wins at pointer-down, before any travel: the first sideways movement
    // (or the release velocity) picks the panel.
    if (travel.dx == 0 &&
        _drawer.value == 0 &&
        _tasks.value == 0 &&
        _tasksSwipeAllowed) {
      _swipePending = true;
      return;
    }
    _swipePending = false;
    final tasks =
        _tasks.value > 0 ||
        (_drawer.value == 0 && _tasksSwipeAllowed && travel.dx < 0);
    _swipeTasks = tasks;
    if (!tasks) return _swipeStart();
    _tasks.stop();
    _dragging = true;
    _tasksRaw = _tasks.value;
    _tasksStartedOpen = _tasks.value >= 0.5;
    _crossed = _tasks.value >= 0.4;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// A swipe accepted before it moved; its direction is not known yet.
  bool _swipePending = false;

  /// Tasks opens with leftward travel ([dx] < 0) and closes with rightward.
  void _followSwipe(double dx) {
    if (_swipePending) {
      if (dx == 0) return;
      _beginSwipe(Offset(dx, 0));
    }
    if (!_swipeTasks) return _swipeUpdate(dx);
    if (!_dragging) return;
    _tasksRaw = (_tasksRaw - dx / _drawerW).clamp(0.0, 1.0);
    _tasks.value = _tasksRaw;
    final crossed = _tasks.value >= 0.4;
    if (!_tasksStartedOpen && crossed && !_crossed) {
      _feedback?.haptic(Haptic.selection);
    }
    _crossed = crossed;
  }

  void _endSwipe(double velocity) {
    if (_swipePending) {
      _swipePending = false;
      if (velocity == 0) return;
      _beginSwipe(Offset(velocity, 0));
    }
    if (!_swipeTasks) return _swipeEnd(velocity);
    if (!_dragging) return;
    _dragging = false;
    _swipeTasks = false;
    // Leftward is "open" for this panel: the drawer's rule, mirrored.
    final open = drawerShouldOpen(
      progress: _tasks.value,
      velocity: -velocity,
      startedOpen: _tasksStartedOpen,
    );
    // A light flick opens it before the 40 % mark: no threshold click yet.
    if (open && !_tasksStartedOpen && !_crossed) {
      _feedback?.haptic(Haptic.selection);
    }
    final target = open ? 1.0 : 0.0;
    if (_tasks.value == target) return;
    if (Motion.reduced(context)) {
      // animateBack at 0, so it ends "dismissed" (see [_spring]).
      final linear = target == 0 ? _tasks.animateBack : _tasks.animateTo;
      linear(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.linear,
      );
      return;
    }
    _spring(
      _tasks,
      SpringSimulation(
        Motion.drawer,
        _tasks.value,
        target,
        -velocity / _drawerW,
      )..tolerance = const Tolerance(distance: 0.001, velocity: 0.01),
      closing: target == 0,
    );
  }

  void _swipeStart() {
    _drawer.stop();
    _dragging = true;
    _raw = _drawer.value.clamp(0.0, 1.0);
    _dragStartedOpen = _drawer.value >= 0.5;
    _crossed = _drawer.value >= 0.4;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _swipeUpdate(double dx) {
    if (!_dragging) return;
    final w = _drawerW;
    _raw = (_raw + dx / w).clamp(0.0, 2.0);
    final v = _raw.clamp(0.0, 1.0) + drawerOvershoot(_raw, w);
    _drawer.value = v.clamp(0.0, _drawer.upperBound);
    final crossed = _drawer.value >= 0.4;
    if (!_dragStartedOpen && crossed && !_crossed) {
      _feedback?.haptic(Haptic.selection);
    }
    _crossed = crossed;
  }

  void _swipeEnd(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    final p = _drawer.value.clamp(0.0, 1.0);
    final open = drawerShouldOpen(
      progress: p,
      velocity: velocity,
      startedOpen: _dragStartedOpen,
    );
    // A light flick opens it before the 40 % mark: no threshold click yet.
    if (open && !_dragStartedOpen && !_crossed) {
      _feedback?.haptic(Haptic.selection);
    }
    _settle(open, velocity);
  }

  /// Spring 500 / 0.9 (Motion.drawer) with the release velocity; 150 ms
  /// linear under reduced motion.
  void _settle(bool open, double velocity) {
    final target = open ? 1.0 : 0.0;
    if (_drawer.value == target) return;
    if (Motion.reduced(context)) {
      // animateBack at 0, so it ends "dismissed" (see [_spring]).
      final linear = target == 0 ? _drawer.animateBack : _drawer.animateTo;
      linear(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.linear,
      );
      return;
    }
    _spring(
      _drawer,
      SpringSimulation(
        Motion.drawer,
        _drawer.value,
        target,
        velocity / _drawerW,
      )..tolerance = const Tolerance(distance: 0.001, velocity: 0.01),
      closing: !open,
    );
  }

  /// [AnimationController.animateWith] always ends "completed", even when
  /// the spring settles at 0. A closing spring must end "dismissed", or the
  /// shell reads a shut panel as open: the starter rows stop, swipe up to
  /// live is refused and Back closes nothing.
  static void _spring(
    AnimationController c,
    Simulation s, {
    required bool closing,
  }) => closing ? c.animateBackWith(s) : c.animateWith(s);

  /// A horizontal scroller at its start edge hands a rightward drag on to
  /// the swipe (§4.3), as on the rest of the chat: the chat list. Its
  /// overscroll becomes progress, its end the release. Only rightward:
  /// flinging a table or gallery to its far end stays a scroll (and never
  /// opens Tasks).
  bool _onPaneScroll(ScrollNotification n) {
    if (_wide || n.metrics.axis != Axis.horizontal) return false;
    switch (n) {
      case OverscrollNotification(:final dragDetails?)
          when !_dragging &&
              _drawer.isDismissed &&
              _tasks.isDismissed &&
              n.overscroll < 0:
        if (ThreadSelection.active.value) return false;
        _handoff = true;
        _beginSwipe(dragDetails.delta);
        _followSwipe(dragDetails.delta.dx);
      case OverscrollNotification(:final dragDetails?) when _handoff:
        _followSwipe(dragDetails.delta.dx);
      case ScrollUpdateNotification(:final dragDetails?) when _handoff:
        // Back toward closed while the scroller moves too.
        if (_drawer.value > 0 || _tasks.value > 0) {
          _followSwipe(dragDetails.delta.dx);
        }
      case ScrollEndNotification() when _handoff:
        _handoff = false;
        _endSwipe(n.dragDetails?.velocity.pixelsPerSecond.dx ?? 0);
      default:
    }
    return false;
  }

  // An unfocused composer: its text field's tap-and-horizontal-drag
  // recognizer sits deeper than any swipe target and wins a sideways drag,
  // though on a phone it does nothing until the field has focus. The shell
  // then follows that pointer itself, from the raw events.
  int? _rawPointer;
  Offset _rawTravel = Offset.zero;
  bool _rawFollowing = false;
  VelocityTracker? _rawVelocity;

  void _onRawDown(PointerDownEvent e) {
    _liveRaw = null;
    _liveRawLost = false;
    _liveRawFollowing = false;
    final liveAt = _liveSwipeAt(e);
    // A finger on the composer, just above it or on the live button: a call
    // may follow, so the bridge readies one (free; round 8 warm start).
    if (liveAt != null || _onLiveButton(e.position)) call.prewarm();
    if (liveAt == true) {
      _liveRaw = e.pointer;
      _liveRawTravel = Offset.zero;
      _liveRawVelocity = VelocityTracker.withKind(e.kind)
        ..addPosition(e.timeStamp, e.position);
    }
    _rawPointer = null;
    _rawFollowing = false;
    if (_wide || _focus.hasFocus || _dragging) return;
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    final r = _rectOf(_composerKey);
    final pane = _paneKey.currentContext?.findRenderObject() as RenderBox?;
    if (r == null || pane == null) return;
    if (!r.contains(pane.globalToLocal(e.position))) return;
    if (!_canSwipeFrom(e)) return;
    _rawPointer = e.pointer;
    _rawTravel = Offset.zero;
    _rawVelocity = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
  }

  void _onRawMove(PointerMoveEvent e) {
    if (e.pointer == _liveRaw) {
      _liveRawTravel += e.delta;
      _liveRawVelocity?.addPosition(e.timeStamp, e.position);
      if (_liveRawFollowing) {
        _followLiveSwipe(-_liveRawTravel.dy);
      } else if (_liveRawLost &&
          !_rawFollowing &&
          !_dragging &&
          LiveSwipeRecognizer.accepts(_liveRawTravel)) {
        _liveRawFollowing = true;
        _beginLiveSwipe();
        _followLiveSwipe(-_liveRawTravel.dy);
      }
    }
    if (e.pointer != _rawPointer) return;
    _rawTravel += e.delta;
    _rawVelocity?.addPosition(e.timeStamp, e.position);
    if (_rawFollowing) _followSwipe(e.delta.dx);
  }

  void _onRawEnd(PointerEvent e) {
    if (e.pointer == _liveRaw) {
      _liveRaw = null;
      if (_liveRawFollowing) {
        _liveRawFollowing = false;
        if (e is PointerUpEvent) {
          final v = _liveRawVelocity?.getVelocity().pixelsPerSecond.dy ?? 0;
          _endLiveSwipe(-v);
        } else {
          _releaseLiveSwipe();
        }
      }
    }
    if (e.pointer != _rawPointer) return;
    _rawPointer = null;
    if (!_rawFollowing) return;
    _rawFollowing = false;
    final v = e is PointerUpEvent
        ? _rawVelocity?.getVelocity().pixelsPerSecond.dx ?? 0
        : 0.0;
    _endSwipe(v);
  }

  /// The sidebar recognizer lost [pointer]. On the unfocused composer, with
  /// the travel so far a valid swipe (not a swipe up to live), follow it.
  void _onSwipeLost(int pointer) {
    if (pointer != _rawPointer || _rawFollowing || _dragging) return;
    if (_focus.hasFocus || _liveSwipe.value > 0) return;
    if (!DrawerSwipeRecognizer.accepts(_rawTravel, _swipeDirection())) return;
    _rawFollowing = true;
    _beginSwipe(_rawTravel);
    _followSwipe(_rawTravel.dx);
  }

  /// One recognizer factory for the shell and every [DrawerSwipeTarget]. Only
  /// the instance that started a drag may end it, so a losing copy's cancel
  /// never closes a drag the winner is following.
  DrawerSwipeRecognizer? _activeSwipe;
  late final _swipeFactory =
      GestureRecognizerFactoryWithHandlers<DrawerSwipeRecognizer>(
        () => DrawerSwipeRecognizer(
          debugOwner: this,
          canStart: _canSwipeFrom,
          direction: _swipeDirection,
          onLost: _onSwipeLost,
        ),
        // Down: the slop travel reaches the panel with the first update, so
        // it follows the finger from the first move instead of lagging 16 dp.
        (r) => r
          ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
          ..dragStartBehavior = DragStartBehavior.down
          ..onStart = ((_) {
            _activeSwipe = r;
            _beginSwipe(r.travel);
          })
          ..onUpdate = ((d) {
            if (identical(_activeSwipe, r)) _followSwipe(d.delta.dx);
          })
          ..onEnd = ((d) {
            if (!identical(_activeSwipe, r)) return;
            _activeSwipe = null;
            _endSwipe(d.velocity.pixelsPerSecond.dx);
          })
          ..onCancel = (() {
            if (!identical(_activeSwipe, r)) return;
            _activeSwipe = null;
            _endSwipe(0);
          }),
      );

  // --- predictive back (§4.4) ----------------------------------------------

  bool get _backClosesDrawer =>
      _drawerOpen &&
      !(_composerKey.currentState?.effortOpen ?? false) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!mounted || !_backClosesDrawer) return false;
    _drawer.stop();
    _backFrom = _drawer.value.clamp(0.0, 1.0);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    final from = _backFrom;
    if (from == null) return;
    _drawer.value = from * (1 - 0.25 * backEvent.progress);
  }

  @override
  void handleCommitBackGesture() {
    if (_backFrom == null) return;
    _backFrom = null;
    _settle(false, 0);
  }

  @override
  void handleCancelBackGesture() {
    if (_backFrom == null) return;
    _backFrom = null;
    _settle(true, 0);
  }

  Future<bool> _confirmLeaveLive(String title) async {
    if (!call.inCall) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('End live voice and open “$title”?'),
        content: const Text('The live session belongs to the current chat.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End and switch'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    await endLive();
    return true;
  }

  Future<void> _select(String id) async {
    if (id == chat.currentConversationId) {
      closeDrawer();
      return;
    }
    final title = widget.conversations.byId(id)?.title ?? 'this chat';
    if (!await _confirmLeaveLive(title)) return;
    closeDrawer();
    unawaited(chat.load(id));
  }

  Future<void> newChat() async {
    if (!await _confirmLeaveLive('a new chat')) return;
    closeDrawer();
    // Already on an empty chat: no transition to notice, so refresh here.
    final wasEmpty = _isEmptyChat;
    chat.newChat();
    if (wasEmpty) _refreshStarters();
    _text.clear();
    // A subtle arrival for the empty chat: fade in, rising 8 dp.
    if (!mounted) return;
    _fresh.duration = Motion.of(context, const Duration(milliseconds: 180));
    _fresh.value = 0;
    unawaited(_fresh.forward());
  }

  void _newChatFromBar() {
    _feedback?.haptic(Haptic.light);
    unawaited(newChat());
  }

  /// Header button size and edge margin (§2.2: 44 dp, 12 dp from the edge;
  /// the 48 dp hit target overhangs the circle by 2 dp).
  static const double _barButton = 44;
  static const double _barEdge = 12 - (Sz.hit - _barButton) / 2;

  Future<void> _deleteChat(String id) async {
    final current = id == chat.currentConversationId;
    if (current && call.inCall) await endLive();
    try {
      await widget.conversations.delete(id);
      if (current) chat.newChat();
    } catch (_) {
      _toasts.show('Couldn’t delete the chat.', kind: ToastKind.error);
    }
  }

  /// The Profile page (name and photo, synced): Settings' first row.
  void openProfile() {
    closeDrawer();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ProfilePage(settings: widget.settings, uploader: _uploader),
      ),
    );
  }

  /// Opens Settings, at [section] when given (the tray's voice row).
  void openSettings({SettingsSection? section}) {
    closeDrawer();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          initialSection: section,
          settings: widget.settings,
          call: call,
          voices: voiceChoices(chat.capabilities.voices),
          effortSupported: chat.capabilities.effort,
          device: widget.device,
          notifyPrefs: widget.notifyPrefs,
          notificationSink: widget.notificationSink,
          push: widget.push,
          instant: widget.instant,
          testEvents: chat.capabilities.events ? chat.api.testEvents : null,
          usageLimits: chat.capabilities.history ? chat.api.usageLimits : null,
          speech: widget.speech,
          links: widget.links,
          capabilities: chat.capabilities,
          onProfile: openProfile,
          data: DataControls.forServer(
            settings: widget.settings,
            capabilities: chat.capabilities,
            conversations: widget.conversations,
            onOpenChat: (id) => unawaited(_select(id)),
            onChatsCleared: () async {
              if (call.inCall) await endLive();
              chat.newChat();
            },
          ),
        ),
      ),
    );
  }

  void _openLiveSettings() => showLiveSettings(
    context,
    call: call,
    settings: widget.settings,
    voices: voiceChoices(chat.capabilities.voices),
    languageSupported: chat.capabilities.language,
  );

  /// The current chat as the list knows it: pin and rename go through the
  /// conversations controller, so its copy is the fresh one.
  Conversation? get _currentConversation {
    final c = chat.conversation;
    return c == null ? null : widget.conversations.byId(c.id) ?? c;
  }

  /// Wide header: the chat's title and a chevron; opens Chat options.
  Widget _titleButton(HermesTokens t) {
    final title = _currentConversation?.title ?? chat.title ?? '';
    return Builder(
      builder: (anchor) => Semantics(
        container: true,
        button: true,
        label: 'Chat options',
        value: title,
        excludeSemantics: true,
        onTap: () => _chatOptions(anchor),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('title-button'),
            borderRadius: BorderRadius.circular(Rad.row),
            onTap: () => _chatOptions(anchor),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: t.row
                          .copyWith(fontSize: 15, height: 20 / 15)
                          .hermesWeight(600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: t.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The header's More (⋮): chat options for a saved chat; on an empty or
  /// unsaved chat, live voice and Settings.
  Future<void> _chatOptions(BuildContext anchor) async {
    final conv = _currentConversation;
    if (conv == null) return _moreOptions(anchor);
    final choice = await showPopover<String>(
      anchor: anchor,
      width: 220,
      above: false,
      align: PopoverAlign.end,
      label: 'Chat options',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopoverItem(
            label: 'Rename',
            icon: Icons.edit_outlined,
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          PopoverItem(
            label: conv.pinned ? 'Unpin' : 'Pin',
            icon: Icons.push_pin_outlined,
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          PopoverItem(
            label: 'Tasks',
            icon: Icons.checklist_rounded,
            onTap: () => Navigator.pop(context, 'tasks'),
          ),
          PopoverItem(
            label: 'Copy chat as text',
            icon: Icons.ios_share_rounded,
            onTap: () => Navigator.pop(context, 'share'),
          ),
          PopoverItem(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        await _rename(conv);
      case 'tasks':
        openTasks();
      case 'pin':
        try {
          await widget.conversations.togglePin(conv.id);
        } catch (_) {}
      case 'share':
        final text = [
          for (final m in chat.messages)
            '${m.isUser ? 'You' : Brand.assistantName}: ${m.text}',
        ].join('\n\n');
        await Clipboard.setData(
          ClipboardData(text: '# ${conv.title}\n\n$text'),
        );
        _toasts.show('Chat copied as text', kind: ToastKind.success);
      case 'delete':
        if (await confirmDeleteChat(context, conv.title)) {
          await _deleteChat(conv.id);
        }
    }
  }

  Future<void> _moreOptions(BuildContext anchor) async {
    final hasMessages = chat.messages.isNotEmpty;
    final choice = await showPopover<String>(
      anchor: anchor,
      width: 220,
      above: false,
      align: PopoverAlign.end,
      label: 'More',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopoverItem(
            label: 'Start live voice',
            icon: Icons.graphic_eq_rounded,
            onTap: () => Navigator.pop(context, 'live'),
          ),
          if (hasMessages)
            PopoverItem(
              label: 'Tasks',
              icon: Icons.checklist_rounded,
              onTap: () => Navigator.pop(context, 'tasks'),
            ),
          PopoverItem(
            label: 'Settings',
            icon: Icons.settings_outlined,
            onTap: () => Navigator.pop(context, 'settings'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'live':
        unawaited(startLive());
      case 'tasks':
        openTasks();
      case 'settings':
        openSettings();
    }
  }

  Future<void> _rename(Conversation conv) async {
    final ctl = TextEditingController(text: conv.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 120,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctl.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (title != null && title.trim().isNotEmpty) {
      try {
        await widget.conversations.rename(conv.id, title.trim());
      } catch (_) {}
    }
  }

  // --- keyboard ------------------------------------------------------------

  bool get _typing => isTypingFocus(FocusManager.instance.primaryFocus);

  void _escape() {
    if (_composerKey.currentState?.effortOpen ?? false) {
      _composerKey.currentState!.closeEffort();
    } else if (_tasksOpen) {
      closeTasks();
    } else if (_drawer.value > 0 && !_wide) {
      closeDrawer();
    } else if (_liveOpen) {
      unawaited(endLive());
    } else if (_typing) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  /// Single-key shortcuts (M mutes). Handled on the shell's own focus node
  /// rather than in [CallbackShortcuts], which marks every matching key as
  /// handled: on the web that swallowed "m" in the composer. While a text
  /// field has focus, or with a modifier held, the key goes on unhandled.
  KeyEventResult _onShellKey(FocusNode node, KeyEvent e) => shellLetterShortcut(
    e,
    typing: _typing,
    inCall: call.inCall,
    toggleMute: call.toggleMute,
  );

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.escape): _escape,
    for (final meta in [false, true]) ...{
      SingleActivator(LogicalKeyboardKey.keyK, control: !meta, meta: meta): () {
        if (!chat.historyAvailable) return;
        if (_wide && widget.settings.sidebarCollapsed) return _searchFromRail();
        if (!_wide) openDrawer();
        _searchRequests.value++;
      },
      SingleActivator(
        LogicalKeyboardKey.keyO,
        control: !meta,
        meta: meta,
        shift: true,
      ): newChat,
      SingleActivator(
        LogicalKeyboardKey.keyL,
        control: !meta,
        meta: meta,
        shift: true,
      ): () =>
          _liveOpen ? endLive() : startLive(),
    },
  };

  // --- desktop sidebar -----------------------------------------------------

  static const double _railWidth = SidebarRail.width;

  /// The open desktop sidebar (the reference layout's 260 dp).
  static const double _sidebarWidth = 260;

  /// Wide layouts only: folds the chat list into the icon rail, or opens it
  /// again (saved on this device). Phones keep their drawer.
  void _setSidebarCollapsed(bool on) {
    final keyboard =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    unawaited(widget.settings.setSidebarCollapsed(on));
    setState(() {});
    // Keyboard users keep their place, on the toggle that replaced the one
    // they pressed; pointer users' focus is left alone.
    if (!keyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (on ? _railExpandFocus : _collapseFocus).requestFocus();
    });
  }

  final _railExpandFocus = FocusNode(debugLabel: 'expand sidebar');
  final _collapseFocus = FocusNode(debugLabel: 'collapse sidebar');

  /// Opens the folded sidebar and focuses its search (rail and Ctrl+K).
  void _searchFromRail() {
    _setSidebarCollapsed(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchRequests.value++;
    });
  }

  String get _serverHost =>
      Uri.tryParse(widget.settings.url)?.host ?? Brand.appName;

  /// The folded sidebar (sidebar_rail.dart).
  Widget _rail(BuildContext context) {
    final t = HermesTokens.of(context);
    return SidebarRail(
      conversations: widget.conversations,
      historyAvailable: chat.historyAvailable,
      serverHost: _serverHost,
      expandFocus: _railExpandFocus,
      onExpand: () => _setSidebarCollapsed(false),
      onNewChat: () => unawaited(newChat()),
      onSearch: _searchFromRail,
      onSelect: (id) => unawaited(_select(id)),
      onSettings: openSettings,
      onTasks: _liveOpen ? null : (_tasksOpen ? closeTasks : openTasks),
      tasksLabel: _workRunning ? 'Tasks, work running' : 'Tasks',
      tasksIcon: _TasksGlyph(
        running: _workRunning,
        color: t.text,
        dot: t.accent,
        size: SidebarRail.icon,
      ),
    );
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= Sz.wideLayout;
    _drawerW = wide ? _sidebarWidth : Sz.drawerWidth(size.width);
    final drawer = ChatDrawer(
      conversations: widget.conversations,
      historyAvailable: chat.historyAvailable,
      serverHost: _serverHost,
      onSelect: _select,
      onNewChat: newChat,
      onSettings: openSettings,
      onDelete: _deleteChat,
      searchRequests: _searchRequests,
      streaming: chat.streamingConversations,
      onCollapse: wide ? () => _setSidebarCollapsed(true) : null,
      collapseFocus: _collapseFocus,
      onTasks: wide && !_liveOpen
          ? (_tasksOpen ? closeTasks : openTasks)
          : null,
      tasksLabel: _workRunning ? 'Tasks, work running' : 'Tasks',
      tasksGlyph: _TasksGlyph(
        running: _workRunning,
        color: t.text,
        dot: t.accent,
        size: 18,
      ),
      profile: widget.settings.profile,
      displayName: widget.settings.displayName,
      profileSource: widget.settings,
      // Round 8: the avatar opens Settings; Profile is its first row.
      onProfile: openSettings,
    );
    final collapsed = wide && widget.settings.sidebarCollapsed;
    final body = wide
        ? Row(
            children: [
              AnimatedContainer(
                key: const ValueKey('sidebar'),
                duration: Motion.of(context, const Duration(milliseconds: 220)),
                curve: Motion.standard,
                width: collapsed ? _railWidth : _sidebarWidth,
                clipBehavior: Clip.hardEdge,
                decoration: const BoxDecoration(),
                child: collapsed
                    ? _rail(context)
                    : OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: _sidebarWidth,
                        maxWidth: _sidebarWidth,
                        child: drawer,
                      ),
              ),
              VerticalDivider(width: 1, thickness: 1, color: t.hairline),
              Expanded(child: _pane(context, wide: true)),
            ],
          )
        : _push(context, drawer);
    return PopScope(
      canPop: !(_drawerOpen || _liveOpen || _tasksOpen || _minimiseOnBack),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleBack();
      },
      child: CallbackShortcuts(
        bindings: _shortcuts,
        child: Focus(
          focusNode: _shellFocus,
          autofocus: true,
          onKeyEvent: _onShellKey,
          child: MarkdownImageScope(
            loader: _imageLoader,
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              backgroundColor: t.bg,
              body: body,
            ),
          ),
        ),
      ),
    );
  }

  /// The push drawer: content slides right by the drawer width while the
  /// drawer slides in, following a swipe from anywhere on the thread
  /// (chat-rendering-v2 §4).
  Widget _push(BuildContext context, Widget drawer) {
    final t = HermesTokens.of(context);
    final w = _drawerW;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Built once per shell build, not per animation frame: a drag or the
    // settling spring only moves them. Building them inside the builder
    // rebuilt about 390 widgets every frame of a swipe (round 6, A1/A5).
    // Their status-dependent parts follow the controllers' status listeners,
    // which rebuild the shell.
    final drawerBox = RepaintBoundary(child: drawer);
    final tasksBox = RepaintBoundary(child: _tasksPanel(t));
    final paneBox = RepaintBoundary(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onPaneScroll,
        child: _pane(context, wide: false),
      ),
    );
    return Listener(
      onPointerDown: _onRawDown,
      onPointerMove: _onRawMove,
      onPointerUp: _onRawEnd,
      onPointerCancel: _onRawEnd,
      behavior: HitTestBehavior.translucent,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        // No semantics node: assistive tech opens the drawer with its button.
        excludeFromSemantics: true,
        gestures: {DrawerSwipeRecognizer: _swipeFactory},
        child: DrawerSwipeScope(
          factory: _swipeFactory,
          child: AnimatedBuilder(
            animation: Listenable.merge([_drawer, _tasks]),
            builder: (context, _) {
              final v = _drawer.value;
              final p = v.clamp(0.0, 1.0);
              final over = (v - 1).clamp(0.0, 1.0) * w;
              final showDrawer = p > 0;
              // Tasks: the mirror of the drawer, in from the right edge
              // following a leftward swipe; the content slides left.
              final q = _tasks.value.clamp(0.0, 1.0);
              final screenW = MediaQuery.sizeOf(context).width;
              final showTasks = q > 0;
              return Stack(
                children: [
                  if (showDrawer)
                    Positioned(
                      left: -w * (1 - p),
                      top: 0,
                      bottom: 0,
                      width: w + over,
                      child: drawerBox,
                    ),
                  if (showTasks)
                    Positioned(
                      left: screenW - w * q,
                      top: 0,
                      bottom: 0,
                      width: w,
                      child: tasksBox,
                    ),
                  Positioned(
                    left: w * p + over - w * q,
                    top: 0,
                    bottom: 0,
                    width: MediaQuery.sizeOf(context).width,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ExcludeSemantics(
                            excluding: p > 0.5 || q > 0.5,
                            child: paneBox,
                          ),
                        ),
                        if (showDrawer || showTasks)
                          Positioned.fill(
                            child: GestureDetector(
                              key: const ValueKey('pane-scrim'),
                              onTap: showDrawer ? closeDrawer : closeTasks,
                              child: ColoredBox(
                                color: Colors.black.withValues(
                                  alpha: (dark ? 0.32 : 0.24) * (p + q),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // The live call's × stays reachable while browsing (§2.4).
                  if (showDrawer && _liveOpen && call.inCall)
                    Positioned(
                      right: Sp.controls - 4,
                      bottom:
                          MediaQuery.viewPaddingOf(context).bottom +
                          Sp.composerBottom -
                          (Sz.hit - Sz.liveControl) / 2,
                      child: Opacity(
                        opacity: p,
                        child: SolidRoundButton(
                          label: 'End live voice',
                          color: t.closeFill,
                          onPressed: endLive,
                          child: Icon(
                            Icons.close_rounded,
                            color: t.onClose,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The chat's Tasks panel, with a hairline on its inner edge (from the
  /// right edge on phones, over the pane's right side on wide layouts).
  Widget _tasksPanel(HermesTokens t) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: t.hairline)),
    ),
    child: ConversationTasksPanel(
      key: const ValueKey('tasks-panel'),
      chat: chat,
      call: call,
      onClose: closeTasks,
      closeFocus: _tasksClose,
    ),
  );

  /// Wide layouts: Tasks slides over the pane's right side (no swipe; the
  /// header button, Escape and the scrim close it).
  Widget _wideTasks(BuildContext context) => AnimatedBuilder(
    animation: _tasks,
    builder: (context, _) {
      final q = _tasks.value.clamp(0.0, 1.0);
      // Always a positioned child: a non-positioned one would make the
      // pane's Stack size itself to it (zero height).
      if (q == 0) {
        return const Positioned(width: 0, height: 0, child: SizedBox());
      }
      final t = HermesTokens.of(context);
      final dark = Theme.of(context).brightness == Brightness.dark;
      return Positioned.fill(
        child: LayoutBuilder(
          builder: (context, box) {
            final pw = (box.maxWidth * 0.9).clamp(0.0, 400.0);
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('pane-scrim'),
                    onTap: closeTasks,
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: (dark ? 0.32 : 0.24) * q,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: -pw * (1 - q),
                  top: 0,
                  bottom: 0,
                  width: pw,
                  child: _tasksPanel(t),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  /// The content pane: thread, live overlay, app bar, composer and toasts.
  Widget _pane(BuildContext context, {required bool wide}) {
    final mq = MediaQuery.of(context);
    final topInset = mq.padding.top + 56;
    final big = mq.textScaler.scale(10) / 10 >= 1.6;
    final composerH = Sz.composerMin + (big && _liveOpen ? 68 : 0);
    final keyboard = mq.viewInsets.bottom;
    final composerBottom = keyboard > 0
        ? keyboard + Sp.s
        : mq.viewPadding.bottom + Sp.composerBottom;
    // The read-aloud capsule (48 + 8 dp) must not cover the last action row.
    final bottomInset =
        (_composerExtent ?? composerBottom + composerH) +
        8 +
        (_playerShown ? 56 : 0);
    final live = _live;
    final caps = chat.capabilities;
    // Wide layouts centre the composer on an empty chat, with the greeting
    // above it and the suggestions below (until the first message, or while
    // a soft keyboard is up).
    final centred = wide && !_liveOpen && keyboard == 0 && _isEmptyChat;
    final reduced = Motion.reduced(context);
    return LayoutBuilder(
      builder: (context, box) {
        final composerTop = box.maxHeight - composerBottom - composerH;
        final extent = _composerExtent ?? composerBottom + composerH;
        final pillH = extent - composerBottom;
        // Centred: the pill's middle 46 % down the pane.
        final lift = centred
            ? (box.maxHeight * 0.54 - composerBottom - pillH / 2).clamp(
                0.0,
                double.infinity,
              )
            : 0.0;
        final columnW = box.maxWidth.clamp(
          0.0,
          Sz.contentMaxWidth + 2 * Sp.controls,
        );
        final pillRect = Rect.fromLTWH(
          (box.maxWidth - columnW) / 2 + Sp.controls,
          box.maxHeight - lift - extent,
          columnW - 2 * Sp.controls,
          pillH,
        );
        return Stack(
          key: _paneKey,
          children: [
            // The thread fades and shrinks to 0.98 as live mode opens, and
            // comes back after the orb has left (§6.4).
            Positioned.fill(
              child: AnimatedBuilder(
                animation: live,
                builder: (context, child) {
                  final v = live.value;
                  final out = live.status == AnimationStatus.reverse
                      ? 1 -
                            const Interval(
                              120 / 340,
                              1,
                              curve: Motion.emphasizedDecel,
                            ).transform(1 - v)
                      : const Interval(
                          0,
                          200 / 420,
                          curve: Motion.exit,
                        ).transform(v);
                  return Offstage(
                    offstage: v >= 1 && _liveOpen,
                    child: Opacity(
                      opacity: (1 - out).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 1 - 0.02 * out,
                        child: child,
                      ),
                    ),
                  );
                },
                child: NotificationListener<Notification>(
                  onNotification: _onThreadNotification,
                  child: ChecklistScope(
                    store: _checklists,
                    child: MessageActions(
                      share: _shareText,
                      email: _email,
                      notify: _notify,
                      readAloud: _readAloud,
                      attachmentImage: _attachmentImage,
                      child: AnimatedBuilder(
                        animation: _fresh,
                        builder: (context, child) {
                          final v = Motion.emphasizedDecel.transform(
                            _fresh.value,
                          );
                          if (v >= 1) return child!;
                          return Opacity(
                            opacity: v,
                            child: Transform.translate(
                              offset: Offset(0, 8 * (1 - v)),
                              child: child,
                            ),
                          );
                        },
                        child: ThreadView(
                          key: _threadKey,
                          chat: chat,
                          scroll: _scroll,
                          topInset: topInset,
                          bottomInset: bottomInset,
                          endGap: replyGap - 8,
                          // Settings › General › Show suggestions.
                          prompts: widget.settings.showSuggestions
                              ? _starters
                              : const [],
                          centredComposer: centred ? pillRect : null,
                          onSuggestion: _send,
                          // The starter rows drift only while the chat shows.
                          startersActive:
                              !_liveOpen &&
                              !_tasks.isCompleted &&
                              (wide || !_drawer.isCompleted),
                          onFocusComposer: _focus.requestFocus,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_liveOpen)
              Positioned.fill(
                // hermes-ui inside live answers: options and buttons post
                // typed turns; suggestions sit under the answer.
                child: HermesUiScope(
                  onSend: _send,
                  onCopy: _copyFromUi,
                  onSelectionHaptic: () => _feedback?.haptic(Haptic.selection),
                  enabled: chat.canSend,
                  child: LiveOverlay(
                    key: _overlayKey,
                    call: call,
                    chat: chat,
                    enter: live,
                    since: _liveSince,
                    topInset: topInset,
                    composerTop: composerTop,
                    heroRect: _heroRect,
                    onRetry: () {
                      unawaited(call.end());
                      _callSeen = false;
                      unawaited(call.start());
                    },
                    blockBuilder: (context, content) => HermesReplyExtras.maybe(
                      content.text,
                      streaming: content.streaming,
                      onSend: chat.canSend ? _send : null,
                    ),
                  ),
                ),
              ),
            // The thread scrolls under the composer and fades out toward the
            // bottom edge: clear [EdgeFeather.aboveComposer] dp above the
            // pill, then deepening to the edge (the keyboard top when it is
            // open). Not on the empty screen, whose chips sit just above the
            // composer, nor in live mode.
            if (!_liveOpen && chat.messages.isNotEmpty)
              Positioned(
                key: const ValueKey('bottom-feather'),
                left: 0,
                right: 0,
                bottom: 0,
                child: EdgeFeather(
                  stops: EdgeFeather.bottomStops(
                    composerExtent:
                        _composerExtent ?? composerBottom + composerH,
                  ),
                ),
              ),
            _appBar(context, wide: wide, topInset: topInset),
            // Swipe up to live: a hint over the composer that fades in with
            // the drag (no pointer, no semantics; the button stays the
            // accessible way in).
            if (!_liveOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: lift + extent + 10,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _liveSwipe,
                      builder: (context, v, _) {
                        if (v <= 0) return const SizedBox.shrink();
                        final t = HermesTokens.of(context);
                        final pull = _livePull;
                        final ready = v >= pull;
                        final progress = (v / pull).clamp(0.0, 1.0);
                        final colour = ready ? t.text : t.textMuted;
                        // Grows with the pull: the label fades in and a thin
                        // bar fills to the threshold, where the label turns
                        // to "Release" (with a haptic tick).
                        return Opacity(
                          key: const ValueKey('live-swipe-hint'),
                          opacity: (progress * 1.6).clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(
                              0,
                              reduced ? 0 : -liveSwipeOffset(v),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    WaveGlyph(color: colour, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      ready
                                          ? 'Release to start live'
                                          : 'Pull to talk',
                                      style: t.label.copyWith(color: colour),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  key: const ValueKey('live-swipe-progress'),
                                  width: 56,
                                  height: 3,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: progress,
                                      heightFactor: 1,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: colour,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            AnimatedPositioned(
              key: const ValueKey('composer-slot'),
              duration: Motion.of(context, const Duration(milliseconds: 280)),
              curve: Motion.standard,
              left: 0,
              right: 0,
              bottom: lift,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Sz.contentMaxWidth + 2 * Sp.controls,
                  ),
                  child: SizeReporter(
                    onSize: _onComposerSize,
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<double>(
                        valueListenable: _liveSwipe,
                        // The rubber band: the composer lifts with the drag.
                        builder: (context, v, child) => v <= 0 || reduced
                            ? child!
                            : Transform.translate(
                                offset: Offset(0, -liveSwipeOffset(v)),
                                child: child,
                              ),
                        child: ListenableBuilder(
                          listenable: widget.settings,
                          builder: (context, _) => Composer(
                            key: _composerKey,
                            controller: _text,
                            focusNode: _focus,
                            live: _liveOpen,
                            streaming: chat.streaming,
                            chatEnabled: caps.chat,
                            effortEnabled: caps.effort,
                            effort: widget.settings.effort,
                            onEffort: widget.settings.setEffort,
                            onSend: _send,
                            onSubmit: _submit,
                            onStop: chat.stop,
                            onStartLive: startLive,
                            muted: call.muted,
                            callFailed: call.phase == CallPhase.failed,
                            onMute: call.toggleMute,
                            onEnd: endLive,
                            onMore: openSettings,
                            // Settings › General › Send with Enter.
                            desktopKeys: widget.settings.sendWithEnter
                                ? null
                                : false,
                            actionKey: _actionKey,
                            attachmentsSupported: caps.attachments,
                            attachments: _attachments,
                            webSearchSupported: caps.webSearch,
                            webSearch: _webSearch,
                            onWebSearch: (on) =>
                                setState(() => _webSearch = on),
                            readAloud:
                                widget.speech?.settings.value.autoReadReplies ??
                                false,
                            onReadAloud: widget.speech == null
                                ? null
                                : (on) => widget.speech!.settings.update(
                                    (s) => s.copyWith(autoReadReplies: on),
                                  ),
                            onVoiceSettings: () =>
                                openSettings(section: SettingsSection.voice),
                            dictation: _dictation,
                            onNotice: (text) => _toasts.show(text),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Swipe up to live starts on the composer or just above it. On
            // top of both, but translucent: taps, the thread's scrolling and
            // the sideways swipes still reach what is underneath, and only
            // an upward drag is claimed (live_swipe.dart).
            if (!_liveOpen && keyboard == 0)
              Positioned(
                key: const ValueKey('live-swipe-zone'),
                left: 0,
                right: 0,
                bottom: lift,
                height: extent + LiveSwipeRecognizer.zone,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  excludeFromSemantics: true,
                  gestures: {LiveSwipeRecognizer: _liveSwipeFactory},
                ),
              ),
            // Read-aloud capsule, 8 dp above the composer (§5.4).
            if (widget.speech != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: (_composerExtent ?? composerBottom + composerH) + 8,
                child: Center(child: ReadAloudPlayer(tts: widget.speech!.tts)),
              ),
            if (wide) _wideTasks(context),
            ToastHost(controller: _toasts, top: 60),
            if (widget.notifier != null && widget.showBanner)
              ReplyNoticeBanner(notifier: widget.notifier!),
          ],
        );
      },
    );
  }

  Widget _appBar(
    BuildContext context, {
    required bool wide,
    required double topInset,
  }) {
    final t = HermesTokens.of(context);
    final canOptions =
        !_liveOpen && chat.historyAvailable && chat.conversation != null;
    // Hidden on an empty new chat (there is nothing to leave).
    final canNewChat =
        !_liveOpen && (chat.messages.isNotEmpty || chat.conversation != null);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: false,
        child: Stack(
          children: [
            // The thread scrolls under the header and fades out toward the
            // top edge, so text passes behind the glass buttons (dimmed, not
            // hidden) and is gone by the top of the screen. It ends where the
            // first message sits at rest (ThreadView's top padding). Live
            // mode keeps its solid scrim behind the status bar and buttons.
            if (_liveOpen)
              IgnorePointer(
                child: Container(
                  height: topInset + ThreadView.underBar,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        t.bg,
                        t.bg,
                        t.bg.withValues(alpha: 0.82),
                        t.bg.withValues(alpha: 0),
                      ],
                      stops: [
                        0,
                        (topInset - 16) / (topInset + ThreadView.underBar),
                        topInset / (topInset + ThreadView.underBar),
                        1,
                      ],
                    ),
                  ),
                ),
              )
            else
              EdgeFeather(
                key: const ValueKey('top-feather'),
                stops: EdgeFeather.topStops(
                  statusBar: MediaQuery.paddingOf(context).top,
                  bar: topInset - MediaQuery.paddingOf(context).top,
                  underBar: ThreadView.underBar,
                ),
              ),
            // Header (chat-rendering-v2 §2.2): 44 dp glass controls, 12 dp
            // from the edges, centred 34 dp below the status bar. On phones
            // New chat and More share one joined pill (round 3, HeaderPill).
            Padding(
              padding: EdgeInsets.fromLTRB(
                _barEdge,
                MediaQuery.paddingOf(context).top + 34 - Sz.hit / 2,
                _barEdge,
                0,
              ),
              child: SizedBox(
                height: Sz.hit,
                child: Row(
                  children: [
                    if (!wide)
                      _BarButton(
                        label: 'Chats',
                        tooltip: 'Chats',
                        size: _barButton,
                        onPressed: openDrawer,
                        child: MenuGlyph(color: t.text, size: 22),
                      ),
                    // Wide: the chat's title with a chevron opens its
                    // options (the phone keeps the title out of the header).
                    if (wide && canOptions)
                      Flexible(child: _titleButton(t))
                    else
                      const Spacer(),
                    if (wide && canOptions) const Spacer(),
                    // Tasks: phones show it while work runs here (the
                    // leftward swipe and the menu open it otherwise); wide
                    // layouts have it in the sidebar and the rail.
                    if (!_liveOpen && !wide && _workRunning)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _BarButton(
                          key: const ValueKey('tasks-button'),
                          label: _workRunning ? 'Tasks, work running' : 'Tasks',
                          tooltip: 'Tasks',
                          size: _barButton,
                          onPressed: _tasksOpen ? closeTasks : openTasks,
                          child: _TasksGlyph(
                            running: _workRunning,
                            color: t.text,
                            dot: t.accent,
                          ),
                        ),
                      ),
                    // The glass edge 12 dp from the screen edge, like the
                    // menu circle (whose 48 dp target overhangs it by 2).
                    Padding(
                      padding: const EdgeInsets.only(
                        right: (Sz.hit - _barButton) / 2,
                      ),
                      child: HeaderPill(
                        key: const ValueKey('header-pill'),
                        height: _barButton,
                        actions: [
                          if (_liveOpen)
                            HeaderPillAction(
                              label: 'Voice settings',
                              tooltip: 'Voice settings',
                              icon: Icon(
                                Icons.tune_rounded,
                                size: 20,
                                color: t.text,
                              ),
                              onPressed: (_) => _openLiveSettings(),
                            )
                          else ...[
                            // Phones: New chat and More share one pill; New
                            // chat leaves on an empty chat (nothing to leave).
                            if (canNewChat && !wide)
                              HeaderPillAction(
                                key: const ValueKey('new-chat'),
                                label: 'New chat',
                                tooltip: 'New chat',
                                icon: ComposeGlyph(color: t.text, size: 22),
                                onPressed: (_) => _newChatFromBar(),
                              ),
                            if (!wide)
                              HeaderPillAction(
                                key: const ValueKey('more-button'),
                                label: canOptions ? 'Chat options' : 'More',
                                tooltip: canOptions ? 'Chat options' : 'More',
                                icon: Icon(
                                  Icons.more_vert_rounded,
                                  size: 22,
                                  color: t.text,
                                ),
                                onPressed: _chatOptions,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A header button with its own semantics node (so its label and bounds are
/// its own, not merged into the header) around a 44 dp [GlassButton].
class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.size,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final String tooltip;
  final double size;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: GlassButton(
      label: label,
      tooltip: tooltip,
      size: size,
      onPressed: onPressed,
      child: child,
    ),
  );
}

/// The Tasks header glyph, with a small dot while work runs in this chat.
class _TasksGlyph extends StatelessWidget {
  const _TasksGlyph({
    required this.running,
    required this.color,
    required this.dot,
    this.size = 20,
  });

  final bool running;
  final Color color;
  final Color dot;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size + 4,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Center(
          child: Icon(Icons.checklist_rounded, size: size, color: color),
        ),
        if (running)
          Positioned(
            right: -1,
            top: 0,
            child: Container(
              key: const ValueKey('tasks-running-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
      ],
    ),
  );
}

/// Whether [f] belongs to a text field. EditableText attaches its node
/// through a [Focus] of its own, so the node's widget is not always the
/// EditableText itself.
bool isTypingFocus(FocusNode? f) {
  final c = f?.context;
  if (c == null) return false;
  return c.widget is EditableText ||
      c.findAncestorStateOfType<EditableTextState>() != null;
}

/// The shell's bare-letter shortcut (M toggles mute during a call). Never
/// while typing or with a modifier held: the key then reaches the text field.
KeyEventResult shellLetterShortcut(
  KeyEvent e, {
  required bool typing,
  required bool inCall,
  required VoidCallback toggleMute,
}) {
  if (e.logicalKey != LogicalKeyboardKey.keyM) return KeyEventResult.ignored;
  if (typing || !inCall) return KeyEventResult.ignored;
  final k = HardwareKeyboard.instance;
  if (k.isControlPressed || k.isMetaPressed || k.isAltPressed) {
    return KeyEventResult.ignored;
  }
  if (k.isShiftPressed) return KeyEventResult.ignored;
  if (e is KeyDownEvent) toggleMute();
  return KeyEventResult.handled;
}

/// [EmailComposer] on Android's intents (Gmail by package, or any email
/// app); a mailto: link elsewhere or when the intent cannot open.
class _DeviceEmailComposer implements EmailComposer {
  _DeviceEmailComposer(this.device);
  final DeviceServices? device;
  static const gmail = 'com.google.android.gm';

  @override
  Future<bool> gmailAvailable() async =>
      await device?.emailApp(package: gmail) ?? false;

  @override
  Future<bool> compose({
    required bool gmail,
    required List<String> to,
    required String subject,
    required String body,
  }) async {
    final d = device;
    if (d != null &&
        await d.composeEmail(
          package: gmail ? _DeviceEmailComposer.gmail : null,
          to: emailAddresses(to),
          subject: subject,
          body: body,
        )) {
      return true;
    }
    return const MailtoComposer().compose(
      gmail: false,
      to: to,
      subject: subject,
      body: body,
    );
  }
}
