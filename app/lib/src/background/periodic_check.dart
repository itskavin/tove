import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../bridge/bridge_api.dart';
import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../chat/models.dart';
import '../config.dart';
import '../notify/notification_sink.dart';
import '../notify/notify_prefs.dart';
import '../notify/reply_notice.dart';
import '../settings/settings.dart';
import 'events_poll.dart';
import 'reply_store.dart';

/// The slow fallback when the app is closed and push is not available (no
/// distributor installed, or a bridge without `push`): Android WorkManager
/// runs [runReplyCheck] about every 15 minutes (the platform minimum; Doze
/// can stretch it to hours) while replies are left in flight. Each run reads
/// the persisted replies, asks the bridge how each ended, and posts a
/// notification for those that finished. It stops itself when none are left.
///
/// Much slower than push or the foreground service; it only covers "the app
/// was swiped away or killed mid-reply".
class ReplyCheckScheduler {
  ReplyCheckScheduler({Workmanager? workmanager})
    : _wm = workmanager ?? Workmanager();

  static const uniqueName = 'hermes.reply-check';
  static const taskName = 'replyCheck';

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final Workmanager _wm;
  bool _initialized = false;
  bool _scheduled = false;

  Future<void> _init() async {
    if (_initialized) return;
    await _wm.initialize(replyCheckDispatcher);
    _initialized = true;
  }

  /// Schedules the check (idempotent). Call when the app leaves the screen
  /// with replies in flight and push is not active.
  Future<void> schedule() async {
    if (!supported || _scheduled) return;
    try {
      await _init();
      await _wm.registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      _scheduled = true;
    } catch (e) {
      debugPrint('Could not schedule the reply check: $e');
    }
  }

  /// Cancels it (no replies left, push became active, sign-out).
  Future<void> cancel() async {
    if (!supported) return;
    try {
      await _init();
      await _wm.cancelByUniqueName(uniqueName);
      _scheduled = false;
    } catch (_) {}
  }
}

/// WorkManager's entry point (a background isolate).
@pragma('vm:entry-point')
void replyCheckDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final settings = SettingsController(
        keys: SecureKeyStore(),
        prefs: SharedPrefsStore(),
      );
      await settings.load();
      if (!settings.hasKey) return true;
      final api = ChatApi(
        baseUrl:
            BridgeApi.parseUrl(settings.url) ?? Uri.parse(kDefaultBridgeUrl),
        accessKey: settings.accessKey,
      );
      try {
        if (isEventsPollTask(task)) {
          await runEventsPoll(
            api: api,
            sink: LocalNotificationSink.platformDefault(),
            store: PrefsEventsCursorStore(),
          );
          return true;
        }
        final left = await runReplyCheck(
          api: api,
          store: PrefsReplyStore(),
          sink: LocalNotificationSink.platformDefault(),
        );
        if (left == 0) await ReplyCheckScheduler().cancel();
      } finally {
        api.close();
      }
    } catch (e) {
      debugPrint('Reply check failed: $e');
    }
    return true;
  });
}

/// One check. Returns how many replies are still in flight on [api]'s
/// bridge afterwards.
Future<int> runReplyCheck({
  required ChatApi api,
  required ReplyStore store,
  required NotificationSink sink,
  Future<bool> Function()? enabled,
  DateTime Function()? now,
  Duration forgetAfter = const Duration(hours: 24),
}) async {
  final server = api.baseUrl.toString();
  final at = (now ?? DateTime.now)();
  final all = await store.load();
  final keep = <InFlightReply>[];
  var left = 0;
  final on = await (enabled ?? ReplyNotificationPrefs.read)();
  for (final e in all) {
    if (e.server != server) {
      keep.add(e);
      continue;
    }
    if (at.difference(e.started) >= forgetAfter) continue;
    ChatMessage? saved;
    try {
      final d = await api.getConversation(e.conversationId, limit: 20);
      for (final m in d.messages) {
        if (m.id == e.messageId) saved = m;
      }
    } on ChatException catch (err) {
      if (err.kind != ChatErrorKind.notFound) {
        keep.add(e);
        left++;
      }
      continue;
    }
    if (saved == null) continue;
    if (saved.isStreaming) {
      keep.add(e);
      left++;
      continue;
    }
    if (on && !e.notified && saved.status != MessageStatus.stopped) {
      final failed =
          saved.status == MessageStatus.failed ||
          saved.status == MessageStatus.interrupted;
      final preview = saved.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      await sink.show(
        ReplyNotice(
          kind: failed ? ReplyNoticeKind.failed : ReplyNoticeKind.reply,
          conversationId: e.conversationId,
          messageId: e.messageId,
          title: e.title,
          preview: preview.isEmpty
              ? null
              : (preview.length > 140
                    ? '${preview.substring(0, 139)}…'
                    : preview),
        ),
      );
    }
  }
  await store.save(keep);
  return left;
}
