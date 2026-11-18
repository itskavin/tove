import 'package:material_ui/material_ui.dart';

/// A [TextEditingController] that can draw a range of not-yet-final
/// dictation words in a muted colour (spec §5.3: partial text in
/// `textMuted`, then `text` when final).
///
/// Optional: the composer works with any controller, and with a plain one
/// the partial words are simply drawn in the normal colour.
class ComposerTextController extends TextEditingController {
  ComposerTextController({super.text});

  TextRange? _pending;
  Color? _pendingColor;

  /// The range drawn muted, or null.
  TextRange? get pending => _pending;

  void setPending(TextRange? range, {Color? color}) {
    if (range == _pending && color == _pendingColor) return;
    _pending = range;
    _pendingColor = color;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final r = _pending;
    final color = _pendingColor;
    if (r == null ||
        color == null ||
        !r.isValid ||
        r.isCollapsed ||
        r.end > text.length) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: r.textBefore(text)),
        TextSpan(
          text: r.textInside(text),
          style: style?.copyWith(color: color) ?? TextStyle(color: color),
        ),
        TextSpan(text: r.textAfter(text)),
      ],
    );
  }
}
