import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../notify/notification_sink.dart';
import '../notify/notify_prefs.dart';
import '../notify/reply_notice.dart';
import 'background_replies.dart';
import 'reply_store.dart';

/// One push from the bridge (API.md "Push notifications"):
/// `{"type", "conversation_id", "message_id", "title", "preview", "status",
/// "sent"}`.
class PushPayload {
  const PushPayload({
    required this.type,
    this.conversationId,
    this.messageId,
    this.title,
    this.preview,
    this.status,
    this.sent,
  });

  /// Null for anything that is not a bridge push (bad JSON, no `type`).
  static PushPayload? parse(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (j is! Map) return null;
      final type = j['type'];
      if (type is! String || type.isEmpty) return null;
      String? s(String k) =>
          j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
      final sent = j['sent'];
      return PushPayload(
        type: type,
        conversationId: s('conversation_id'),
        messageId: s('message_id'),
        title: s('title'),
        preview: s('preview'),
        status: s('status'),
        sent: sent is num
            ? DateTime.fromMillisecondsSinceEpoch(sent.toInt())
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// `chat.reply`, `live.task` or `test`.
  final String type;
  final String? conversationId;
  final String? messageId;

  /// Null with `push_previews: false`.
  final String? title;
  final String? preview;

  /// `done`, `failed` or `stopped`.
  final String? status;
  final DateTime? sent;

  /// What to show; null for a stopped reply and unknown types.
  ReplyNotice? toNotice() {
    final kind = switch (type) {
      'chat.reply' => switch (status) {
        'stopped' => null,
        'failed' || 'error' => ReplyNoticeKind.failed,
        _ => ReplyNoticeKind.reply,
      },
      'live.task' => switch (status) {
        'failed' || 'error' => ReplyNoticeKind.taskFailed,
        _ => ReplyNoticeKind.task,
      },
      'test' => ReplyNoticeKind.test,
      _ => null,
    };
    if (kind == null) return null;
    return ReplyNotice(
      kind: kind,
      conversationId: conversationId,
      messageId: messageId,
      title: title,
      preview: preview,
    );
  }
}

/// The UnifiedPush calls the registrar needs (a seam for tests).
abstract class PushTransport {
  Future<void> initialize({
    required void Function(String endpoint) onEndpoint,
    required void Function(String reason) onFailed,
    required void Function() onUnregistered,
    required void Function(Uint8List content) onMessage,
  });

  /// Installed distributor packages (ntfy: `io.heckel.ntfy`).
  Future<List<String>> distributors();

  /// Uses the saved distributor, else the system default. False: ask.
  Future<bool> useCurrentOrDefault();
  Future<void> saveDistributor(String id);
  Future<void> register();
  Future<void> unregister();
}

/// `package:unifiedpush` (Android; Linux through D-Bus).
class UnifiedPushTransport implements PushTransport {
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Future<void> initialize({
    required void Function(String endpoint) onEndpoint,
    required void Function(String reason) onFailed,
    required void Function() onUnregistered,
    required void Function(Uint8List content) onMessage,
  }) async {
    await UnifiedPush.initialize(
      onNewEndpoint: (e, _) => onEndpoint(e.url),
      onRegistrationFailed: (r, _) => onFailed(r.name),
      onUnregistered: (_) => onUnregistered(),
      onMessage: (m, _) => onMessage(m.content),
      linuxDBusName: 'io.github.tovechat.tove',
    );
  }

  @override
  Future<List<String>> distributors() => UnifiedPush.getDistributors();
  @override
  Future<bool> useCurrentOrDefault() =>
      UnifiedPush.tryUseCurrentOrDefaultDistributor();
  @override
  Future<void> saveDistributor(String id) => UnifiedPush.saveDistributor(id);
  @override
  Future<void> register() => UnifiedPush.register();
  @override
  Future<void> unregister() => UnifiedPush.unregister();
}

enum PushState {
  /// Not on this platform (iOS, web, desktop other than Linux).
  unsupported,

  /// The bridge has no push, or reply notifications are off.
  off,

  /// No distributor app installed: install ntfy (or another). Until then the
  /// 15-minute WorkManager check is the fallback.
  needsDistributor,

  /// Several distributors and none chosen: show [PushRegistrar.distributors].
  choosing,

  /// Waiting for an endpoint or the bridge.
  registering,

  /// The bridge pushes to this device.
  active,

  /// The bridge refused (too many devices, push disabled) or the
  /// distributor failed. [PushRegistrar.problem] says why.
  failed,
}

/// Registers this install with the bridge's push routes and turns incoming
/// pushes into notices while the app runs.
///
/// The app calls [start] after capabilities are known (and when the
/// notification switch turns on), [signOut] on sign-out. Incoming pushes go
/// to [onNotice] (normally `ReplyNotifier.announce`, which shows a system
/// notification only when the app is not visible).
class PushRegistrar extends ChangeNotifier {
  PushRegistrar({
    required this.replies,
    required this.prefs,
    required this.onNotice,
    PushTransport? transport,
    SharedPreferencesAsync? store,
    this.appVersion,
  }) : _transport =
           transport ??
           (UnifiedPushTransport.supported ? UnifiedPushTransport() : null),
       _store = store ?? SharedPreferencesAsync() {
    prefs.addListener(_onPrefs);
  }

  static const deviceIdKey = 'push.device_id';
  static const endpointKey = 'push.endpoint';

  /// Where to get ntfy, the distributor this app suggests.
  static const ntfyFdroid = 'https://f-droid.org/packages/io.heckel.ntfy/';
  static const ntfyPlay =
      'https://play.google.com/store/apps/details?id=io.heckel.ntfy';

  final BackgroundReplies replies;
  final ReplyNotificationPrefs prefs;
  final void Function(ReplyNotice notice) onNotice;
  final String? appVersion;
  final PushTransport? _transport;
  final SharedPreferencesAsync _store;

  ChatApi? _api;
  bool _initialized = false;
  PushState _state = PushState.off;
  List<String> _distributors = const [];
  String? _problem;
  bool _previews = true;

  PushState get state => _transport == null ? PushState.unsupported : _state;
  List<String> get distributors => _distributors;
  String? get problem => _problem;

  /// The bridge sends titles and previews (`push_previews`).
  bool get previews => _previews;

  void _set(PushState s, [String? problem]) {
    _state = s;
    _problem = problem;
    replies.pushActive = s == PushState.active;
    notifyListeners();
  }

  /// Starts (or refreshes) push for [api]'s bridge.
  Future<void> start(ChatApi api) async {
    _api = api;
    final t = _transport;
    if (t == null) return;
    final caps = api.cachedCapabilities ?? await api.capabilities();
    if (!caps.unifiedPush || !prefs.enabled) {
      _set(PushState.off);
      return;
    }
    _previews = caps.pushPreviews;
    try {
      if (!_initialized) {
        await t.initialize(
          onEndpoint: (e) => unawaited(_onEndpoint(e)),
          onFailed: (r) => _set(PushState.failed, 'The push app failed ($r)'),
          onUnregistered: () => unawaited(_onUnregistered()),
          onMessage: _onMessage,
        );
        _initialized = true;
      }
      if (await t.useCurrentOrDefault()) {
        _set(PushState.registering);
        await t.register();
        return;
      }
      _distributors = await t.distributors();
      _set(
        _distributors.isEmpty ? PushState.needsDistributor : PushState.choosing,
      );
    } catch (e) {
      _set(PushState.failed, 'Push is not available: $e');
    }
  }

  /// The user picked one of [distributors].
  Future<void> chooseDistributor(String id) async {
    final t = _transport;
    if (t == null) return;
    await t.saveDistributor(id);
    _set(PushState.registering);
    await t.register();
  }

  Future<String> deviceId() async {
    var id = await _store.getString(deviceIdKey);
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id =
          'app-${List.generate(16, (_) => r.nextInt(36).toRadixString(36)).join()}';
      await _store.setString(deviceIdKey, id);
    }
    return id;
  }

  Future<void> _onEndpoint(String endpoint) async {
    final api = _api;
    await _store.setString(endpointKey, endpoint);
    if (api == null || !prefs.enabled) return;
    try {
      _previews = await api.registerPush(
        deviceId: await deviceId(),
        endpoint: endpoint,
        appVersion: appVersion,
      );
      _set(PushState.active);
    } on ChatException catch (e) {
      _set(PushState.failed, switch (e.code) {
        'too_many_devices' =>
          'The server already has 10 devices. Remove one there first',
        'push_disabled' => 'The server has push turned off',
        _ => e.message,
      });
    }
  }

  Future<void> _onUnregistered() async {
    await _store.remove(endpointKey);
    _set(PushState.off);
  }

  void _onMessage(Uint8List content) {
    final notice = PushPayload.parse(content)?.toNotice();
    if (notice != null) onNotice(notice);
  }

  void _onPrefs() {
    final api = _api;
    if (api == null) return;
    if (prefs.enabled) {
      unawaited(start(api));
    } else {
      unawaited(_unregister(api));
    }
  }

  Future<void> _unregister(ChatApi api) async {
    try {
      await api.unregisterPush(await deviceId());
    } on ChatException {
      // Best effort; the bridge drops endpoints that return 404/410.
    }
    try {
      await _transport?.unregister();
    } catch (_) {}
    await _store.remove(endpointKey);
    _set(PushState.off);
  }

  /// Sign-out: the bridge forgets this device and the distributor drops the
  /// registration.
  Future<void> signOut() async {
    final api = _api;
    if (api != null) await _unregister(api);
    _api = null;
  }

  /// `POST /api/push/test`.
  Future<bool> sendTest() async {
    final api = _api;
    if (api == null || state != PushState.active) return false;
    try {
      return await api.testPush(await deviceId());
    } on ChatException {
      return false;
    }
  }

  @override
  void dispose() {
    prefs.removeListener(_onPrefs);
    super.dispose();
  }
}

/// The flag `UnifiedPushService` passes when it starts a Dart engine for a
/// push that arrived while the app was not running.
const kUnifiedPushBackgroundArg = '--unifiedpush-bg';

/// Call first in `main(List<String> args)`: when the app was started only to
/// receive a push, this handles it (a notification, if the switch is on)
/// and returns true; `main` must then return without `runApp`.
///
/// A new endpoint that arrives here is saved and registered by the next
/// [PushRegistrar.start] in the full app.
Future<bool> handlePushInBackground(
  List<String> args, {
  NotificationSink? sink,
}) async {
  if (!args.contains(kUnifiedPushBackgroundArg)) return false;
  WidgetsFlutterBinding.ensureInitialized();
  final out = sink ?? LocalNotificationSink.platformDefault();
  final store = SharedPreferencesAsync();
  await UnifiedPush.initialize(
    onMessage: (m, _) => unawaited(
      handlePushMessage(m.content, sink: out, replyStore: PrefsReplyStore()),
    ),
    onNewEndpoint: (e, _) =>
        unawaited(store.setString(PushRegistrar.endpointKey, e.url)),
    onUnregistered: (_) => unawaited(store.remove(PushRegistrar.endpointKey)),
  );
  return true;
}

/// A push while no reader is open: shows it (unless reply notifications are
/// off) and marks the persisted reply as announced, so a later resume does
/// not announce it again. Returns the notice shown, if any.
Future<ReplyNotice?> handlePushMessage(
  List<int> content, {
  required NotificationSink sink,
  ReplyStore? replyStore,
  Future<bool> Function()? enabled,
}) async {
  final notice = PushPayload.parse(content)?.toNotice();
  if (notice == null) return null;
  if (!await (enabled ?? ReplyNotificationPrefs.read)()) return null;
  await sink.show(notice);
  final id = notice.messageId;
  if (replyStore != null && id != null) {
    final all = await replyStore.load();
    if (all.any((e) => e.messageId == id)) {
      await replyStore.save([
        for (final e in all)
          if (e.messageId == id) e.copyWith(notified: true) else e,
      ]);
    }
  }
  return notice;
}
