// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:treep/main.dart';

void main() {
  testWidgets('Treep home screen renders basic controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TreepApp());

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Choose journey'), findsOneWidget);
    expect(find.text('Alarm offset'), findsNothing);
    expect(find.byKey(const Key('alarm-offset-slider')), findsNothing);
    expect(find.text('Test GTFS-RT feed'), findsOneWidget);
    expect(find.textContaining('Test alarm'), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });
}
