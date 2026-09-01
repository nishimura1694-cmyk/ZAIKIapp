import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/app_bottom_sheet.dart';

void main() {
  testWidgets('shows the widget built by the builder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showAppBottomSheet(
                context: context,
                builder: (_) => const Text('シートの中身'),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    expect(find.text('シートの中身'), findsOneWidget);
  });
}
