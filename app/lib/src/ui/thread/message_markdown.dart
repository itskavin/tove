import 'package:material_ui/material_ui.dart';

import '../markdown/hermes_markdown.dart';

/// The one place the thread and the live canvas render message markdown
/// (spec §5.2, §5.3).
///
/// [text] is everything received so far; [streaming] is true while more
/// arrives. A message that was seen streaming keeps the streaming renderer
/// after it completes, so the rate smoothing can flush (≤ 300 ms) and the
/// trailing fade can finish; others render statically. Selection comes from
/// the caller's [SelectionArea].
class MessageMarkdown extends StatefulWidget {
  const MessageMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.onRevealed,
  });

  final String text;
  final bool streaming;

  /// Called once the whole text is on screen after the stream ended.
  final VoidCallback? onRevealed;

  @override
  State<MessageMarkdown> createState() => _MessageMarkdownState();
}

class _MessageMarkdownState extends State<MessageMarkdown> {
  late bool _streamed = widget.streaming;

  @override
  void didUpdateWidget(MessageMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming) _streamed = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_streamed) return HermesMarkdown(text: widget.text);
    return StreamingMarkdown(
      text: widget.text,
      isStreaming: widget.streaming,
      onRevealed: widget.onRevealed,
    );
  }
}
