import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/common/floating_sheet.dart';
import 'package:tove_chat/src/ui/common/glass.dart';
import 'package:tove_chat/src/ui/common/glyphs.dart';
import 'package:tove_chat/src/ui/common/popover.dart';
import 'package:tove_chat/src/ui/common/toast.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

void main() {
  testWidgets('glass buttons expose labels and 48 dp targets', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Center(
            child: GlassButton(
              label: 'Chats',
              onPressed: () => taps++,
              child: const MenuGlyph(),
            ),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Chats'), findsOneWidget);
    expect(tester.getSize(find.byType(GlassButton)), const Size(48, 48));
    await tester.tap(find.bySemanticsLabel('Chats'));
    expect(taps, 1);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('glass falls back to an opaque fill without blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      themed(
        const Glass(child: SizedBox(width: 40, height: 40)),
        policy: RenderPolicy(blur: false, monitor: false),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(
      themed(
        const Glass(child: SizedBox(width: 40, height: 40)),
        policy: RenderPolicy(blur: true, monitor: false),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('popover returns focus to its anchor', (tester) async {
    final anchorFocus = FocusNode(debugLabel: 'anchor');
    addTearDown(anchorFocus.dispose);
    String? picked;
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                focusNode: anchorFocus,
                onPressed: () async {
                  picked = await showPopover<String>(
                    anchor: context,
                    builder: (context) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PopoverItem(
                          label: 'Speaker',
                          checked: true,
                          onTap: () => Navigator.pop(context, 'speaker'),
                        ),
                        PopoverItem(
                          label: 'Phone',
                          onTap: () => Navigator.pop(context, 'phone'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Audio output'),
              ),
            ),
          ),
        ),
      ),
    );
    anchorFocus.requestFocus();
    await tester.pump();
    await tester.tap(find.text('Audio output'));
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsOneWidget);
    expect(anchorFocus.hasFocus, isFalse, reason: 'focus is in the popover');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Phone'), findsNothing);
    expect(anchorFocus.hasFocus, isTrue);
    expect(picked, isNull);

    await tester.tap(find.text('Audio output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();
    expect(picked, 'phone');
  });

  testWidgets('floating sheet: inner push/back and swipe to dismiss', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFloatingSheet<void>(
                context,
                page: SheetPage(
                  title: 'Settings',
                  builder: (context) => TextButton(
                    onPressed: () => SheetPager.of(context).push(
                      SheetPage(
                        title: 'Choose a voice',
                        heightFraction: 0.75,
                        builder: (_) => const Center(child: Text('Cove')),
                      ),
                    ),
                    child: const Text('Voice'),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a voice'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    // The voice page is 75 % of the screen tall.
    final sheetHeight = tester.getSize(find.byType(SheetPager)).height;
    expect(sheetHeight, closeTo(915 * 0.75, 1));

    // System back pops the inner page first, not the sheet.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    await tester.drag(find.text('Settings'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('a toast replaces the previous one and auto-dismisses', (
    tester,
  ) async {
    final toasts = ToastController();
    addTearDown(toasts.dispose);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Stack(children: [ToastHost(controller: toasts)]),
        ),
      ),
    );
    toasts.show('First');
    await tester.pump();
    toasts.show('Second', kind: ToastKind.error);
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);

    toasts.show('Lost', onAction: () {}, actionLabel: 'Retry');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Lost'), findsOneWidget, reason: 'actions stay');
  });
}
