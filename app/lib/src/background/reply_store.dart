import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the app remembers about a reply that was still being written, so a
/// cold start (or the 15-minute check) can resume it or report it.
///
/// No secrets: the access key stays in the settings' secure store.
class InFlightReply {
  const InFlightReply({
    required this.server,
    required this.messageId,
    required this.conversationId,
    required this.started,
    this.lastEventId,
    this.text,
    this.title,
    this.notified = false,
  });

  static InFlightReply? fromJson(Object? j) {
    if (j is! Map) return null;
    final server = j['server'], message = j['message_id'];
    final conv = j['conversation_id'], started = j['started'];
    if (server is! String || message is! String || conv is! String) {
      return null;
    }
    if (started is! num) return null;
    final last = j['last_event_id'];
    return InFlightReply(
      server: server,
      messageId: message,
      conversationId: conv,
      started: DateTime.fromMillisecondsSinceEpoch(started.toInt()),
      lastEventId: last is num ? last.toInt() : null,
      text: j['text'] is String ? j['text'] as String : null,
      title: j['title'] is String ? j['title'] as String : null,
      notified: j['notified'] == true,
    );
  }

  /// The bridge base URL the reply runs on.
  final String server;

  /// The assistant message id from `meta`.
  final String messageId;
  final String conversationId;
  final DateTime started;

  /// The newest SSE id processed (for `Last-Event-ID`). Only stored
  /// together with [text]: resuming after an id needs the text up to it.
  final int? lastEventId;

  /// The reply text up to [lastEventId].
  final String? text;

  /// Longest [text] kept; longer replies resume from the start instead.
  static const maxText = 64 * 1024;

  /// The chat title when the reply started, for a notification.
  final String? title;

  /// A notification for the end of this reply was already shown (push or the
  /// periodic check), so a later resume must not show another.
  final bool notified;

  InFlightReply copyWith({String? title, bool? notified}) => InFlightReply(
        server: server,
        messageId: messageId,
        conversationId: conversationId,
        started: started,
        lastEventId: lastEventId,
        text: text,
        title: title ?? this.title,
        notified: notified ?? this.notified,
      );

  Map<String, Object?> toJson() => {
    'server': server,
    'message_id': messageId,
    'conversation_id': conversationId,
    'started': started.millisecondsSinceEpoch,
    if (lastEventId != null && text != null) ...{
      'last_event_id': lastEventId,
      'text': text,
    },
    'title': ?title,
    if (notified) 'notified': true,
  };
}

/// Where in-flight replies are kept between launches.
abstract class ReplyStore {
  Future<List<InFlightReply>> load();
  Future<void> save(List<InFlightReply> replies);
}

/// For tests, web, and anything that does not need cold-start resume.
class MemoryReplyStore implements ReplyStore {
  MemoryReplyStore([List<InFlightReply> initial = const []])
    : _items = List.of(initial);

  List<InFlightReply> _items;
  int saves = 0;

  List<InFlightReply> get items => List.unmodifiable(_items);

  @override
  Future<List<InFlightReply>> load() async => List.of(_items);

  @override
  Future<void> save(List<InFlightReply> replies) async {
    saves++;
    _items = List.of(replies);
  }
}

/// `shared_preferences` (DataStore on Android, so it also works from the
/// push and WorkManager background isolates). Corrupt data reads as empty.
class PrefsReplyStore implements ReplyStore {
  PrefsReplyStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  static const key = 'replies.inflight.v1';
  final SharedPreferencesAsync _prefs;

  @override
  Future<List<InFlightReply>> load() async {
    try {
      final raw = await _prefs.getString(key);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [for (final e in list) ?InFlightReply.fromJson(e)];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<InFlightReply> replies) async {
    try {
      if (replies.isEmpty) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(
          key,
          jsonEncode([for (final r in replies) r.toJson()]),
        );
      }
    } catch (_) {
      // Best effort: resume after a cold start is a convenience.
    }
  }
}
