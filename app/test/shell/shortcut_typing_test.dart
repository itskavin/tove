import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/shell/chat_shell.dart';

/// Web regression (round 6, A9): "m" could not be typed because the mute
/// shortcut claimed the key even with the composer focused.
void main() {
  Future<({List<int> mutes, FocusNode field, FocusNode shell})> pump(
    WidgetTester tester, {
    required bool inCall,
  }) async {
    final mutes = <int>[];
    final field = FocusNode();
    final shell = FocusNode();
    final text = TextEditingController();
    addTearDown(() {
      field.dispose();
      shell.dispose();
      text.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Focus(
            focusNode: shell,
            autofocus: true,
            onKeyEvent: (_, e) => shellLetterShortcut(
              e,
              typing: isTypingFocus(FocusManager.instance.primaryFocus),
              inCall: inCall,
              toggleMute: () => mutes.add(1),
            ),
            child: TextField(focusNode: field, controller: text),
          ),
        ),
      ),
    );
    return (mutes: mutes, field: field, shell: shell);
  }

  testWidgets('M is left to a focused text field, even in a call', (
    tester,
  ) async {
    final h = await pump(tester, inCall: true);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(isTypingFocus(FocusManager.instance.primaryFocus), isTrue);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(handled, isFalse, reason: 'the key must reach the field');
    expect(h.mutes, isEmpty);
  });

  testWidgets('M mutes in a call when no field has focus', (tester) async {
    final h = await pump(tester, inCall: true);
    h.shell.requestFocus();
    await tester.pump();
    expect(isTypingFocus(FocusManager.instance.primaryFocus), isFalse);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyM), isTrue);
    expect(h.mutes, hasLength(1));
  });

  testWidgets('M outside a call, or with a modifier, is not claimed', (
    tester,
  ) async {
    final h = await pump(tester, inCall: false);
    h.shell.requestFocus();
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyM), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyM), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(h.mutes, isEmpty);
  });

  testWidgets('typed text keeps every m', (tester) async {
    await pump(tester, inCall: true);
    await tester.enterText(find.byType(TextField), 'mmm');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(find.text('mmm'), findsOneWidget);
  });
}
