import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/empty_state.dart';

void main() {
  testWidgets('EmptyStateView shows the message and icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EmptyStateView(message: 'データがありません')),
      ),
    );

    expect(find.text('データがありません'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
  });

  testWidgets('EmptyStateView renders the optional action', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmptyStateView(
            message: '該当なし',
            action: ElevatedButton(onPressed: () {}, child: const Text('再読込')),
          ),
        ),
      ),
    );

    expect(find.text('再読込'), findsOneWidget);
  });

  testWidgets('LoadingView shows a progress indicator', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoadingView())),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
