/// The assistant-message markdown renderer (redesign spec §5.2, §5.3).
///
/// - [HermesMarkdown]: a complete message.
/// - [StreamingMarkdown]: a reply that is still arriving.
/// - [MarkdownStyle]: colours, text styles and spacing (from the design
///   tokens by default).
///
/// Both widgets take the full width they are given, never scroll vertically,
/// and are selectable inside a [SelectionArea].
library;

import 'package:material_ui/material_ui.dart';

import 'markdown_style.dart';
import 'md_render.dart';
import 'streaming_text.dart';

export 'code_block.dart' show CodeBlock;
export 'links.dart' show confirmAndOpen, safeLink, linkHost;
export 'markdown_style.dart' show MarkdownStyle;
export 'md_images.dart'
    show
        BridgeImageLoader,
        LinkImage,
        LinkImageResult,
        MarkdownImageLoader,
        MarkdownImageScope;
export 'md_render.dart' show MarkdownLinkTap;
export 'md_table.dart' show MdTable;
export 'source_pill.dart' show SourcePill;
export 'streaming_text.dart' show StreamingMarkdown;

/// A complete markdown message, rendered at once with no animation.
///
/// GitHub-flavoured markdown: headings, paragraphs, bold, italic,
/// strikethrough, inline code, fenced code blocks with a Copy button, lists
/// and task lists, tables (scrolling horizontally), block quotes, rules,
/// links and "Sources:" lines as source pills. A paragraph of images shows
/// image cards loaded through the bridge when a [MarkdownImageScope] gives a
/// loader; other images are "[image: alt]" pills (never loaded directly).
///
/// The same renderer as [StreamingMarkdown] with `isStreaming: false`; a
/// message that was streamed can keep its [StreamingMarkdown] once done.
class HermesMarkdown extends StatelessWidget {
  const HermesMarkdown({
    super.key,
    required this.text,
    this.style,
    this.onLinkTap,
    this.selectable = false,
  });

  final String text;

  /// Defaults to [MarkdownStyle.of].
  final MarkdownStyle? style;

  /// Called with a tapped link's destination. Defaults to a confirm sheet
  /// showing the host, then the external browser.
  final MarkdownLinkTap? onLinkTap;

  /// Wraps the message in its own [SelectionArea].
  final bool selectable;

  @override
  Widget build(BuildContext context) => StreamingMarkdown(
    text: text,
    isStreaming: false,
    style: style,
    onLinkTap: onLinkTap,
    selectable: selectable,
  );
}
