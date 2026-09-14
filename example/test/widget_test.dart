import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:example/main.dart';

void main() {
  testWidgets('connection form defaults to certificate verification', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('MSSQL Client Demo'), findsOneWidget);
    expect(find.text('Connect'), findsWidgets);
    final trust = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(trust.value, isFalse);
    expect(find.byType(TextField), findsNWidgets(7));
    expect(tester.takeException(), isNull);
  });
}
