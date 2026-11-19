import 'platform/coarse_location.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'background/background.dart';
import 'bridge/bridge_api.dart';
import 'call/call_controller.dart';
import 'chat/chat.dart';
import 'sync/sync_events.dart';
import 'config.dart';
import 'notify/notify.dart';
import 'pairing/pair_link.dart';
import 'pairing/pairing.dart';
import 'platform/app_links.dart';
import 'platform/device.dart';
import 'settings/appearance.dart';
import 'settings/settings.dart';
import 'speech/speech.dart';
import 'ui/feedback.dart';
import 'ui/onboarding_screen.dart';
import 'ui/pairing/pairing_page.dart';
import 'ui/pairing/scan_page.dart';
import 'ui/pairing/welcome_screen.dart';
import 'ui/shell/chat_shell.dart';
import 'ui/theme/motion.dart';
import 'ui/theme/render_policy.dart';
import 'ui/theme/theme.dart';
import 'update/update_check.dart';
import 'update/update_ui.dart';
import 'brand.dart';

export 'ui/shell/chat_shell.dart' show LiveLink;

/// The app version sent with push registration (pubspec `version`).
const kAppVersion = '1.0.0+1';

/// Long-lived services created in `main` (all optional, so tests and other
/// platforms run without them).
class AppServices {
  const AppServices({
    this.replies,
    this.notifyPrefs,
    this.notificationSink,
    this.instant,
    this.speech,
    this.links,
    this.updates,
  });

  /// The shared reply manager; null gives each chat controller a private one.
  final BackgroundReplies? replies;
  final ReplyNotificationPrefs? notifyPrefs;
  final NotificationSink? notificationSink;

  /// Android's instant notifications (a foreground service holding the
  /// bridge's events stream); null elsewhere.
  final InstantNotifications? instant;
  final SpeechServices? speech;

  /// Home-screen widgets and the assistant gesture (Android).
  final AppLinks? links;

  /// The GitHub Releases check (Android); null elsewhere and in tests.
  final UpdateChecker? updates;

  bool get notifications =>
      replies != null && notifyPrefs != null && notificationSink != null;
}

typedef ChatApiFactory = ChatApi Function(SettingsController settings);

ChatApi defaultChatApi(SettingsController s) => ChatApi(
  baseUrl: BridgeApi.parseUrl(s.url) ?? Uri.parse(kDefaultBridgeUrl),
  accessKey: s.accessKey,
);

class HermesApp extends StatefulWidget {
  const HermesApp({
    super.key,
    required this.settings,
    required this.call,
    this.verify = verifyWithBridge,
    this.pair = pairWithBridge,
    this.scan = scanQrCode,
    this.canScan,
    this.liveLink,
    this.chatApi = defaultChatApi,
    this.device,
    this.feedbackSink,
    this.renderPolicy,
    this.services = const AppServices(),
  });

  final SettingsController settings;
  final CallController call;
  final KeyVerifier verify;

  /// Trades a pairing code for the access key (`POST /api/pair`).
  final Pairer pair;

  /// Reads a QR code with the camera; [canScan] null = phones only.
  final QrScanner scan;
  final bool? canScan;
  final LiveLink? liveLink;
  final ChatApiFactory chatApi;
  final DeviceServices? device;
  final FeedbackSink? feedbackSink;
  final RenderPolicy? renderPolicy;
  final AppServices services;

  @override
  State<HermesApp> createState() => _HermesAppState();
}

class _HermesAppState extends State<HermesApp> {
  late final RenderPolicy _policy = widget.renderPolicy ?? RenderPolicy();
  late final DeviceServices _device = widget.device ?? DeviceServices();
  late final AppFeedback _feedback = AppFeedback(
    settings: widget.settings,
    sink: widget.feedbackSink ?? PlatformFeedbackSink(_device),
  );
  late final LiveLink _liveLink = widget.liveLink ?? LiveLink();

  /// The signed-in session's reply notifier, for the banner layer above
  /// every route.
  final _banner = ValueNotifier<ReplyNotifier?>(null);

  /// Pairing links (`tove://pair?…`, Android) are handled here, signed in or
  /// not, so they work on the welcome screen too. The start-up update dialog
  /// shows through it as well.
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<PairLink>? _pairLinks;
  bool _initialPairAsked = false;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    final links = widget.services.links;
    if (links != null) {
      _pairLinks = links.pairs.listen((l) => unawaited(_onPairLink(l)));
      widget.settings.addListener(_askInitialPair);
      _askInitialPair();
    }
    _policy.start();
    _device.refreshMode = widget.settings.refreshRate;
    widget.settings.addListener(_onRefreshSetting);
    unawaited(_device.watchTouches());
    unawaited(
      _device.androidSdk().then((sdk) {
        if (sdk != null) _policy.applyAndroidSdk(sdk);
      }),
    );
    final updates = widget.services.updates;
    if (updates != null) {
      // A few seconds in, so it never competes with the first chat load.
      _updateTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        unawaited(
          runStartupUpdateCheck(updates, () => _navigator.currentContext),
        );
      });
    }
  }

  Widget _withUpdates(Widget child) {
    final updates = widget.services.updates;
    return updates == null
        ? child
        : UpdateScope(checker: updates, child: child);
  }

  void _onRefreshSetting() => _device.refreshMode = widget.settings.refreshRate;

  /// The link that started the app, once settings are loaded (so it is
  /// known whether a connection would be replaced).
  void _askInitialPair() {
    if (_initialPairAsked || !widget.settings.loaded) return;
    _initialPairAsked = true;
    widget.settings.removeListener(_askInitialPair);
    final links = widget.services.links!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        links.initialPair().then((l) {
          if (l != null && mounted) unawaited(_onPairLink(l));
        }),
      );
    });
  }

  Future<void> _onPairLink(PairLink link) async {
    final nav = _navigator.currentState;
    if (nav == null || !mounted) return;
    final settings = widget.settings;
    if (settings.hasKey) {
      final current = Uri.tryParse(settings.url);
      final same =
          current != null &&
          current.scheme == link.server.scheme &&
          current.host == link.server.host &&
          current.port == link.server.port;
      final ok = await showDialog<bool>(
        context: nav.context,
        builder: (context) => AlertDialog(
          title: Text(
            same
                ? 'Pair again?'
                : 'Connect to ${link.name ?? link.server.host}?',
          ),
          content: Text(
            same
                ? 'Tove will get a fresh connection to this server.'
                : 'Tove will switch to this server. Your chats on the '
                      'current server stay there.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Connect'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    nav.popUntil((r) => r.isFirst);
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => PairingPage(
          link: link,
          settings: settings,
          pair: widget.pair,
          verify: widget.verify,
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_pairLinks?.cancel());
    widget.settings.removeListener(_askInitialPair);
    _updateTimer?.cancel();
    widget.settings.removeListener(_onRefreshSetting);
    if (widget.renderPolicy == null) _policy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        navigatorKey: _navigator,
        title: Brand.appName,
        debugShowCheckedModeBanner: false,
        // Settings › General: accent; Accessibility: contrast.
        theme: applyAppearance(
          buildTheme(Brightness.light),
          accent: settings.accent,
          highContrast: settings.highContrast,
        ),
        darkTheme: applyAppearance(
          buildTheme(Brightness.dark),
          accent: settings.accent,
          highContrast: settings.highContrast,
        ),
        themeMode: switch (settings.theme) {
          AppTheme.light => ThemeMode.light,
          AppTheme.dark => ThemeMode.dark,
          AppTheme.system => ThemeMode.system,
        },
        builder: (context, child) => MotionScope(
          reduce: settings.reduceMotion,
          child: RenderPolicyScope(
            policy: _policy,
            child: FeedbackScope(
              feedback: _feedback,
              // Settings › Text size (this device).
              child: AppTextScale(
                factor: settings.textSize.factor,
                // Reply banners show over every page, Settings included.
                child: ReplyBannerLayer(
                  notifier: _banner,
                  child: _withUpdates(child!),
                ),
              ),
            ),
          ),
        ),
        home: !settings.loaded
            ? const Scaffold(body: SizedBox.expand())
            : settings.hasKey
            ? _ChatHome(
                key: ValueKey(Object.hash(settings.url, settings.accessKey)),
                settings: settings,
                call: widget.call,
                liveLink: _liveLink,
                chatApi: widget.chatApi,
                device: _device,
                services: widget.services,
                banner: _banner,
              )
            : WelcomeScreen(
                settings: settings,
                verify: widget.verify,
                pair: widget.pair,
                scan: widget.scan,
                canScan: widget.canScan,
              ),
      ),
    );
  }
}

/// Owns the chat controllers for one server and key.
class _ChatHome extends StatefulWidget {
  const _ChatHome({
    super.key,
    required this.settings,
    required this.call,
    required this.liveLink,
    required this.chatApi,
    required this.device,
    required this.services,
    this.banner,
  });

  final SettingsController settings;
  final CallController call;
  final LiveLink liveLink;
  final ChatApiFactory chatApi;
  final DeviceServices device;
  final AppServices services;

  /// Where this session's notifier is published for [ReplyBannerLayer].
  final ValueNotifier<ReplyNotifier?>? banner;

  @override
  State<_ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<_ChatHome> {
  late final ChatApi _api = widget.chatApi(widget.settings);
  late final ConversationsController _conversations = ConversationsController(
    api: _api,
  );
  late final ChatController _chat = ChatController(
    api: _api,
    conversations: _conversations,
    defaultEffort: () => chatEffort(widget.settings.effort),
    replies: widget.services.replies,
  );
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () {
      // An unknown result (offline at start) is retried on return.
      if (!_chat.capabilities.known) unawaited(_chat.init());
    },
    onHide: () => unawaited(widget.services.speech?.trimMemory()),
  );

  /// Reply notices (banner, system notification) and push, when available.
  ReplyNotifier? _notifier;
  PushRegistrar? _push;

  /// The bridge's events stream (API.md "Events"): announcements, and chat
  /// refreshes when a live task starts or ends.
  EventsHub? _hub;
  StreamSubscription<BridgeEvent>? _forwarded;
  String? _deviceId;
  DateTime? _listRefreshed;

  late final LocationService _location = LocationService(
    settings: widget.settings,
    device: widget.device,
  );

  @override
  void initState() {
    super.initState();
    _api.location = _location.wire;
    if (_location.available) widget.settings.enableLocation = _location.enable;
    final s = widget.services;
    if (s.notifications) {
      final notifier = ReplyNotifier(
        replies: s.replies!,
        sink: s.notificationSink!,
        onScreenConversation: () => _chat.currentConversationId,
        systemEnabled: () => s.notifyPrefs!.enabled,
      );
      _notifier = notifier;
      // After this frame: the layer sits above this widget.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.banner?.value = notifier;
      });
      _push = PushRegistrar(
        replies: s.replies!,
        prefs: s.notifyPrefs!,
        onNotice: notifier.announce,
        appVersion: kAppVersion,
      );
      final instant = s.instant;
      _hub = EventsHub(
        api: _api,
        announce: notifier.announce,
        onEvent: _onBridgeEvent,
        // One connection: the Android service's, when it runs.
        useOwnStream: () => !(instant?.active ?? false),
        deviceId: () => _deviceId,
      )..bindLifecycle();
      if (instant != null) {
        _forwarded = instant.events.listen(_hub!.handle);
        notifier.addOpens(instant.opens);
        instant.addListener(_onInstant);
      }
      s.notifyPrefs!.addListener(_configureNotifications);
    }
    unawaited(_start());
    _lifecycle;
    if (s.links != null) {
      _chat.addListener(_syncRecentChat);
      _conversations.addListener(_syncRecentChat);
    }
  }

  /// The quick widget's last chat: the chat on screen once it has an id;
  /// cleared when that chat is gone from the list.
  void _syncRecentChat() {
    final links = widget.services.links;
    if (links == null) return;
    final id = _chat.currentConversationId;
    if (id != null) {
      unawaited(
        links.setRecentChat(id, _conversations.byId(id)?.title ?? _chat.title),
      );
      return;
    }
    final recent = links.recentChatId;
    if (recent != null &&
        _conversations.loaded &&
        _conversations.byId(recent) == null) {
      unawaited(links.setRecentChat(null, null));
    }
  }

  Future<void> _start() async {
    // Every request carries this install's id, so the sync events it
    // causes come back with it as `origin` and are skipped here.
    final push = _push;
    _deviceId = push != null
        ? await push.deviceId()
        : await installDeviceId(widget.settings.prefs);
    _api.deviceId = _deviceId;
    if (!mounted) return;
    await _chat.init();
    if (!mounted) return;
    if (push != null) unawaited(push.start(_api));
    await _configureNotifications();
  }

  bool _instantWasActive = false;

  void _onInstant() {
    final active = widget.services.instant?.active ?? false;
    if (active == _instantWasActive) return;
    _instantWasActive = active;
    _hub?.refresh();
    unawaited(_schedulePoll());
  }

  /// Starts or stops the Android service and the background check for the
  /// current bridge, switch and capabilities.
  Future<void> _configureNotifications() async {
    final s = widget.services;
    final hub = _hub;
    if (!mounted || hub == null) return;
    final caps = _chat.capabilities;
    // The service first, so the hub knows whether to open a stream itself.
    await s.instant?.configure(
      bridgeOffers: caps.events,
      url: widget.settings.url,
      accessKey: widget.settings.accessKey,
      systemEnabled: s.notifyPrefs!.enabled,
      deviceId: _deviceId,
      heartbeat: caps.eventsHeartbeat,
    );
    if (!mounted) return;
    hub.setSupported(caps.events);
    hub.refresh();
    await _schedulePoll();
  }

  /// The 15-minute check runs when instant notifications do not.
  Future<void> _schedulePoll() async {
    final s = widget.services;
    final caps = _chat.capabilities;
    final instantOn =
        (s.instant?.supported ?? false) && s.instant!.enabled && caps.events;
    if (caps.events && s.notifyPrefs!.enabled && !instantOn) {
      await EventsPollScheduler().schedule();
    } else {
      await EventsPollScheduler().cancel();
    }
  }

  /// An event about the chat on screen re-reads it (a live task started or
  /// ended, the assistant posted); the chat list refreshes at most every 5 s.
  void _onBridgeEvent(BridgeEvent e) {
    if (!mounted) return;
    // Sync events (round 6) carry the changed row: apply it in place, and
    // re-read the open chat only when its messages changed elsewhere.
    if (syncEventTypes.contains(e.type)) {
      final effect = applySyncEvent(
        e,
        _conversations,
        ownDevice: _deviceId,
        openId: _chat.currentConversationId,
      );
      if (effect == SyncEffect.openChat) unawaited(_chat.refreshCurrent());
      return;
    }
    final here =
        e.conversationId != null &&
        e.conversationId == _chat.currentConversationId;
    if (here) unawaited(_chat.refreshCurrent());
    final now = DateTime.now();
    final last = _listRefreshed;
    if (last == null || now.difference(last) > const Duration(seconds: 5)) {
      _listRefreshed = now;
      unawaited(_conversations.refresh());
    }
  }

  @override
  void dispose() {
    if (widget.settings.enableLocation == _location.enable) {
      widget.settings.enableLocation = null;
    }
    _location.dispose();
    _lifecycle.dispose();
    _chat.removeListener(_syncRecentChat);
    _conversations.removeListener(_syncRecentChat);
    _forwarded?.cancel();
    widget.services.instant?.removeListener(_onInstant);
    widget.services.notifyPrefs?.removeListener(_configureNotifications);
    _hub?.dispose();
    _chat.dispose();
    _conversations.dispose();
    final banner = widget.banner;
    if (banner != null && identical(banner.value, _notifier)) {
      // Not during this frame's finalisation: the layer is an ancestor.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(banner.value, _notifier)) banner.value = null;
      });
    }
    _notifier?.dispose();
    final push = _push;
    final replies = widget.services.replies;
    final signedOut = !widget.settings.hasKey;
    if (signedOut) {
      unawaited(widget.services.links?.setRecentChat(null, null));
      unawaited(push?.signOut());
      unawaited(widget.services.instant?.signOut());
      if (widget.services.notifications) {
        unawaited(ReplyCheckScheduler().cancel());
        unawaited(EventsPollScheduler().cancel());
      }
    }
    push?.dispose();
    // Detach this server's readers before closing their client, or they keep
    // reconnecting on a closed client. The shared manager itself lives on.
    if (replies != null) {
      final api = _api;
      unawaited(
        replies
            .detachAll(forget: signedOut, server: api.baseUrl.toString())
            .whenComplete(api.close),
      );
    } else {
      _api.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LocationScope(service: _location, child: _shell());

  Widget _shell() => ChatShell(
    settings: widget.settings,
    call: widget.call,
    chat: _chat,
    conversations: _conversations,
    liveLink: widget.liveLink,
    device: widget.device,
    notifier: _notifier,
    push: _push,
    notifyPrefs: widget.services.notifyPrefs,
    notificationSink: widget.services.notificationSink,
    instant: widget.services.instant,
    speech: widget.services.speech,
    links: widget.services.links,
    // The app's banner layer shows it above every route.
    showBanner: widget.banner == null,
  );
}
