import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/shell/edge_feather.dart';

/// Round 6 (A7): both side panels keep their header in place over the chat
/// screen's top feather, and the list scrolls under it.
void main() {
  testWidgets('the header stays put while the list scrolls under the feather', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.reset);
    double? inset;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: FeatheredHeader(
            color: const Color(0xFF202020),
            header: const SizedBox(
              key: ValueKey('header'),
              height: 60,
              child: Text('Tasks'),
            ),
            body: (top) {
              inset = top;
              return ListView(
                padding: EdgeInsets.only(top: top),
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 48, child: Text('Row $i')),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(inset, 24 + 60, reason: 'status bar plus the measured header');
    final header = tester.getRect(find.byKey(const ValueKey('header')));
    expect(header.top, 24);
    expect(tester.getTopLeft(find.text('Row 0')).dy, 84);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('header'))), header);
    expect(tester.getTopLeft(find.text('Row 9')).dy, closeTo(116, 1));

    // The same feather as the chat screen: its stops, the panel's colour.
    final feather = tester.widget<EdgeFeather>(find.byType(EdgeFeather));
    expect(feather.color, const Color(0xFF202020));
    expect(
      feather.stops,
      EdgeFeather.topStops(
        statusBar: 24,
        bar: 60,
        underBar: EdgeFeather.underHeader,
      ),
    );
  });

  test('the chat list bottom fade starts clear (a feather, not a band)', () {
    final stops = EdgeFeather.bottomStops(composerExtent: 60);
    expect(EdgeFeather.alphaAt(stops, 0), 0);
    expect(EdgeFeather.alphaAt(stops, 10), lessThan(0.05));
    expect(EdgeFeather.alphaAt(stops, stops.last.at), EdgeFeather.bottomEdge);
  });
}
