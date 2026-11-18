import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/theme/motion.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Hosts [child] the way a thread does: full width with 16 dp gutters,
/// inside a vertical scroll view and a SelectionArea.
Widget host(
  Widget child, {
  double textScale = 1,
  bool disableAnimations = false,
  bool reduceSetting = false,
}) {
  return MaterialApp(
    theme: buildTheme(Brightness.dark),
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: MotionScope(reduce: reduceSetting, child: c!),
    ),
    home: Scaffold(
      body: SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: child,
        ),
      ),
    ),
  );
}

/// Sets the test surface to [width] × [height] logical pixels at 1×.
void setSurface(WidgetTester tester, double width, [double height = 900]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// All visible text, one paragraph per line, without inline placeholders.
String visibleText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText(includePlaceholders: false))
    .join('\n');

/// The first [TextSpan] whose own text is [text].
TextSpan? spanWithText(WidgetTester tester, String text) {
  TextSpan? found;
  for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
    r.text.visitChildren((s) {
      if (s is TextSpan && s.text == text) {
        found = s;
        return false;
      }
      return true;
    });
    if (found != null) return found;
  }
  return null;
}

/// The effective style of the first span containing [text] (merging the
/// root style of its paragraph).
TextStyle? styleOf(WidgetTester tester, String text) {
  for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
    TextStyle? hit;
    void walk(InlineSpan s, TextStyle? inherited) {
      if (hit != null) return;
      final st = inherited?.merge(s.style) ?? s.style;
      if (s is TextSpan) {
        if (s.text != null && s.text!.contains(text)) {
          hit = st;
          return;
        }
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c, st);
        }
      }
    }

    walk(r.text, null);
    if (hit != null) return hit;
  }
  return null;
}
