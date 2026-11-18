import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'chat_errors.dart';

/// Why a reply is reported (API.md "Reports"). [wire] is what the bridge
/// accepts.
enum ReportReason {
  offensive('offensive', 'Offensive', 'Hateful, harassing or sexual'),
  harmful('harmful', 'Harmful or unsafe', 'Dangerous advice or content'),
  wrong('wrong', 'Wrong or misleading', 'Made-up facts or bad sources'),
  other('other', 'Something else', 'Tell us in the note');

  const ReportReason(this.wire, this.label, this.hint);
  final String wire;
  final String label;
  final String hint;
}

/// What the user chose in the Report reply sheet.
@immutable
class ReplyReport {
  const ReplyReport({required this.reason, this.note = '', this.hide = true});
  final ReportReason reason;
  final String note;

  /// Also hide the reply on this device.
  final bool hide;

  /// The note limit the bridge accepts.
  static const noteChars = 1000;
}

/// How a report went: [sent] reached the bridge; [hidden] the reply is now
/// hidden on this device.
typedef ReportOutcome = ({bool sent, bool hidden});

/// Sends [report] for [messageId] to the user's own bridge and, when asked,
/// hides the reply on this device. Hiding never depends on the bridge.
Future<ReportOutcome> submitReport(
  ChatApi api, {
  required String messageId,
  String? conversationId,
  required ReplyReport report,
  HiddenReplies? hidden,
}) async {
  var sent = false;
  try {
    await api.reportMessage(
      messageId: messageId,
      conversationId: conversationId,
      reason: report.reason.wire,
      note: report.note.length > ReplyReport.noteChars
          ? report.note.substring(0, ReplyReport.noteChars)
          : report.note,
      hidden: report.hide,
    );
    sent = true;
  } on ChatException catch (e) {
    debugPrint('Report not sent: ${e.kind}');
  }
  if (report.hide) await (hidden ?? HiddenReplies.instance).hide(messageId);
  return (sent: sent, hidden: report.hide);
}

/// Replies the user hid on this device (after reporting them). Stored in
/// shared_preferences by message id; the bridge keeps the reply.
class HiddenReplies extends ChangeNotifier {
  HiddenReplies({SharedPreferencesAsync? prefs}) : _prefsArg = prefs;

  static HiddenReplies? _instance;
  static HiddenReplies get instance => _instance ??= HiddenReplies();

  @visibleForTesting
  static set instance(HiddenReplies? value) => _instance = value;

  static const key = 'chat.hidden_replies';

  /// The newest ids kept (older ones fall off).
  static const keep = 500;

  final SharedPreferencesAsync? _prefsArg;
  SharedPreferencesAsync get _prefs => _prefsArg ?? SharedPreferencesAsync();
  final List<String> _ids = [];
  Future<void>? _loading;

  bool isHidden(String id) => _ids.contains(id);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final saved = await _prefs.getStringList(key) ?? const [];
      for (final id in saved) {
        if (!_ids.contains(id)) _ids.add(id);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> hide(String id) async {
    await load();
    if (_ids.contains(id)) return;
    _ids.add(id);
    if (_ids.length > keep) _ids.removeRange(0, _ids.length - keep);
    notifyListeners();
    await _save();
  }

  Future<void> unhide(String id) async {
    await load();
    if (!_ids.remove(id)) return;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      await _prefs.setStringList(key, List.of(_ids));
    } catch (_) {}
  }
}
