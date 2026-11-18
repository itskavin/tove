import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../markdown/email_card.dart' show EmailComposer;

/// What "Read aloud" needs from the speech module (chat-rendering-v2 §5.4).
///
/// The shell adapts `lib/src/speech/` to this; with no adapter the button is
/// hidden. [reading] is the id of the message being read, or null.
abstract class ReadAloud implements Listenable {
  bool get available;
  String? get reading;
  Future<void> toggle(ChatMessage message);
}

/// Callbacks the thread's message actions use, provided by the shell so the
/// thread widgets stay free of platform code.
class MessageActions extends InheritedWidget {
  const MessageActions({
    super.key,
    required super.child,
    required this.share,
    required this.notify,
    this.readAloud,
    this.attachmentImage,
    this.email,
  });

  /// Hands email drafts to a mail app (Gmail or a mailto: link); null uses
  /// a plain mailto: link.
  final EmailComposer? email;

  /// Shares plain text (system share sheet, or a copy when there is none).
  final Future<void> Function(String text) share;

  /// A short confirmation toast ("Copied").
  final void Function(String text) notify;
  final ReadAloud? readAloud;

  /// Loads a sent attachment (with the access key): the preview for
  /// thumbnails, the original for the viewer. Null shows placeholders.
  final ImageProvider? Function(MessageAttachment a, {required bool preview})?
  attachmentImage;

  static MessageActions? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessageActions>();

  @override
  bool updateShouldNotify(MessageActions old) =>
      share != old.share ||
      notify != old.notify ||
      readAloud != old.readAloud ||
      attachmentImage != old.attachmentImage ||
      email != old.email;
}
