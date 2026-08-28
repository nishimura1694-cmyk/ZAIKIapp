import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/skeleton_list.dart';

void main() {
  testWidgets('renders the requested number of placeholder rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SkeletonList(itemCount: 4))),
    );
    await tester.pump();

    expect(find.byType(Container), findsNWidgets(4));
  });

  testWidgets('disposes its animation controller cleanly', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SkeletonList())),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
  });
}
