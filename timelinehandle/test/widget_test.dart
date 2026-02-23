// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:timelinehandle/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const TimelineHandlerApp());

    // Verify that our app shows the title.
    expect(find.text('Timeline Handler'), findsOneWidget);

    // Verify that we have the navigation bar items
    expect(find.text('Import & Export'), findsOneWidget);
    expect(find.text('Location Manager'), findsOneWidget);
    expect(find.text('Map Viewer'), findsOneWidget);
  });
}
