import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../notify/events_hub.dart' show noticeForEvent;
import '../notify/notification_sink.dart';
import '../notify/notify_prefs.dart';
import 'periodic_check.dart' show replyCheckDispatcher;

/// The fallback when instant notifications are off (or not on this
/// platform): WorkManager asks the bridge's `GET /api/events?once=1` about
/// every 15 minutes (Doze can stretch it to hours) and posts a notification
/// for each reply, task or assistant message that ended since the last check.
/// About one small HTTPS request per run; nothing runs between checks.
class EventsPollScheduler {
  EventsPollScheduler({Workmanager? workmanager})
    : _wm = workmanager ?? Workmanager();

  static const uniqueName = 'tove.events-poll';
  static const taskName = 'eventsPoll';

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final Workmanager _wm;
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    await _wm.initialize(replyCheckDispatcher);
    _initialized = true;
  }

  Future<void> schedule() async {
    if (!supported) return;
    try {
      await _init();
      await _wm.registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e) {
      debugPrint('Could not schedule the events check: $e');
    }
  }

  Future<void> cancel() async {
    if (!supported) return;
    try {
      await _init();
      await _wm.cancelByUniqueName(uniqueName);
    } catch (_) {}
  }
}

/// Where the background check left off, per bridge, and which messages it
/// already announced.
abstract class EventsCursorStore {
  Future<int?> cursor(String server);
  Future<void> setCursor(String server, int id);

  /// True the first time [messageId] is claimed (the last 200 are kept).
  Future<bool> claim(String messageId);
}

class PrefsEventsCursorStore implements EventsCursorStore {
  PrefsEventsCursorStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;
  static const _cursorKey = 'events.cursor.';
  static const _claimedKey = 'events.claimed';

  @override
  Future<int?> cursor(String server) async {
    try {
      return await _prefs.getInt('$_cursorKey$server');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setCursor(String server, int id) async {
    try {
      await _prefs.setInt('$_cursorKey$server', id);
    } catch (_) {}
  }

  @override
  Future<bool> claim(String messageId) async {
    try {
      final list = await _prefs.getStringList(_claimedKey) ?? <String>[];
      if (list.contains(messageId)) return false;
      list.add(messageId);
      while (list.length > 200) {
        list.removeAt(0);
      }
      await _prefs.setStringList(_claimedKey, list);
    } catch (_) {}
    return true;
  }
}

class MemoryEventsCursorStore implements EventsCursorStore {
  final cursors = <String, int>{};
  final claimed = <String>[];

  @override
  Future<int?> cursor(String server) async => cursors[server];
  @override
  Future<void> setCursor(String server, int id) async => cursors[server] = id;
  @override
  Future<bool> claim(String messageId) async {
    if (claimed.contains(messageId)) return false;
    claimed.add(messageId);
    return true;
  }
}

/// One background check. The first run on a bridge only records where the
/// stream is (old events are not announced). Returns how many notices were
/// posted, or -1 when the bridge could not be asked.
Future<int> runEventsPoll({
  required ChatApi api,
  required NotificationSink sink,
  required EventsCursorStore store,
  Future<bool> Function()? enabled,
}) async {
  final server = api.baseUrl.toString();
  final on = await (enabled ?? ReplyNotificationPrefs.read)();
  var cursor = await store.cursor(server);
  var shown = 0;
  try {
    for (var page = 0; page < 5; page++) {
      final r = await api.eventsSince(cursor ?? 0);
      if (cursor == null || r.reset == 'unknown_id') {
        // First run (or a new database): start from now.
        await store.setCursor(server, r.lastId);
        return 0;
      }
      for (final e in r.events) {
        final notice = noticeForEvent(e);
        if (!on || notice == null || e.type == 'test') continue;
        final id = notice.messageId;
        if (id != null && !await store.claim(id)) continue;
        await sink.show(notice);
        shown++;
      }
      cursor = r.lastId;
      await store.setCursor(server, cursor);
      if (!r.more) break;
    }
  } on ChatException {
    return -1;
  }
  return shown;
}

/// Hands the cursor over when the service stops (instant turned off), so the
/// poll does not re-announce what the service already showed.
Future<void> handOverCursor(
  String server,
  int lastId, {
  EventsCursorStore? store,
}) => (store ?? PrefsEventsCursorStore()).setCursor(server, lastId);

/// For the WorkManager dispatcher.
bool isEventsPollTask(String task) => task == EventsPollScheduler.taskName;
