import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cobblehype_launcher/main.dart';

void main() {
  testWidgets('App smoke test — rota inicial renderiza', (WidgetTester tester) async {
    await tester.pumpWidget(const CobbleHypeApp());
    await tester.pump();
    // Apenas verifica que o app inicializou sem crash
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
