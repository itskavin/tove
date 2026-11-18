import 'dart:math';

import '../chat/conversations_controller.dart';
import '../chat/events.dart';
import '../chat/models.dart';
import '../settings/prefs_store.dart';

/// What a sync event asks of the open chat.
enum SyncEffect {
  /// Nothing (not a sync event, or this device made the change).
  none,

  /// The chat list was updated in place.
  list,

  /// The open chat changed elsewhere: re-read it.
  openChat,
}

/// The sync event types (API.md "Sync events", round 6).
const syncEventTypes = {
  'conversation.created',
  'conversation.title',
  'conversation.updated',
  'conversation.deleted',
  'message.created',
  'message.deleted',
  'reply.started',
};

/// Applies one sync event to the chat list, idempotently (events are hints
/// in id order). Events whose `origin` is [ownDevice] are skipped: this
/// device already has the change. Returns whether the open chat
/// ([openId]) must be re-read.
SyncEffect applySyncEvent(
  BridgeEvent e,
  ConversationsController list, {
  required String? ownDevice,
  required String? openId,
}) {
  if (!syncEventTypes.contains(e.type)) return SyncEffect.none;
  if (ownDevice != null && e.origin == ownDevice) return SyncEffect.none;
  final id = e.conversationId;
  if (id == null) return SyncEffect.none;
  if (e.type == 'conversation.deleted') {
    list.remove(id);
    return SyncEffect.list;
  }
  final c = e.conversation;
  if (c != null) {
    try {
      list.upsert(Conversation.fromJson(c));
    } catch (_) {
      // A malformed row: the next list refresh corrects it.
    }
  }
  final open = id == openId;
  final touchesMessages = switch (e.type) {
    'message.created' || 'message.deleted' || 'reply.started' => true,
    'conversation.updated' => e.changes.contains('messages'),
    _ => false,
  };
  final retitled = e.type == 'conversation.title';
  return open && (touchesMessages || retitled)
      ? SyncEffect.openChat
      : SyncEffect.list;
}

/// This install's id for `X-Device-Id` when there is no push registration
/// to borrow one from: 1–64 of `A-Z a-z 0-9 _ -`, kept in [prefs].
Future<String> installDeviceId(PrefsStore prefs) async {
  const key = 'device.id';
  final saved = await prefs.get(key);
  if (saved != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(saved)) {
    return saved;
  }
  final r = Random.secure();
  final id =
      'app-${List.generate(16, (_) => r.nextInt(36).toRadixString(36)).join()}';
  await prefs.set(key, id);
  return id;
}
