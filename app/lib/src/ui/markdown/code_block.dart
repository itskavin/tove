import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'markdown_style.dart';

/// A fenced code block (chat-rendering-v2 §1.7): `surface` fill, radius 16,
/// 16 dp padding, a header with the language label (caption style, as
/// written) and an icon-only 40 dp Copy button, and horizontal
/// scrolling instead of wrapping, so long lines never overflow at any text
/// scale.
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.style,
    this.span,
  });

  /// The code as copied to the clipboard.
  final String code;

  /// The fence's info string, shown in the header (`code` when empty).
  final String? language;

  /// Defaults to [MarkdownStyle.of].
  final MarkdownStyle? style;

  /// An optional styled rendering of [code] (the streaming fade). Its text
  /// must equal [code].
  final InlineSpan? span;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  static const _feedback = Duration(milliseconds: 1500);

  bool _copied = false;
  Timer? _reset;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _reset?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(_feedback, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style ?? MarkdownStyle.of(context);
    final lang = (widget.language ?? '').trim();
    final pad = s.codeBlockPadding;
    return Semantics(
      container: true,
      label: lang.isEmpty ? 'Code' : 'Code, $lang',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(s.codeBlockRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(
                      child: SelectionContainer.disabled(
                        child: Text(
                          lang.isEmpty ? 'code' : lang,
                          style: s.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  SelectionContainer.disabled(
                    child: Semantics(
                      container: true,
                      liveRegion: _copied,
                      button: true,
                      label: _copied ? 'Copied' : 'Copy code',
                      excludeSemantics: true,
                      onTap: _copy,
                      child: Tooltip(
                        message: _copied ? 'Copied' : 'Copy code',
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: InkResponse(
                            onTap: _copy,
                            radius: 20,
                            child: Icon(
                              _copied
                                  ? Icons.check_rounded
                                  : Icons.copy_rounded,
                              size: 18,
                              color: s.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(pad, 0, pad, pad),
                child: Text.rich(
                  widget.span ?? TextSpan(text: widget.code),
                  style: s.code,
                  softWrap: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
