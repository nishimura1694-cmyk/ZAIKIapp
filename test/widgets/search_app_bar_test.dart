import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/search_app_bar.dart';

void main() {
  testWidgets('shows the title and hint text', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: SearchAppBar(
            title: '会場一覧',
            controller: controller,
            hintText: '会場名・部屋名で検索...',
          ),
        ),
      ),
    );

    expect(find.text('会場一覧'), findsOneWidget);
    expect(find.text('会場名・部屋名で検索...'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('reports text changes via onChanged', (tester) async {
    final controller = TextEditingController();
    String? lastValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: SearchAppBar(
            title: '予約履歴',
            controller: controller,
            hintText: '顧客・会場名で検索...',
            onChanged: (value) => lastValue = value,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'テスト');
    expect(lastValue, 'テスト');
  });

  testWidgets('renders the optional filter row', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: SearchAppBar(
            title: '会場一覧',
            controller: controller,
            hintText: '検索...',
            filterRow: const Text('すべて'),
          ),
        ),
      ),
    );

    expect(find.text('すべて'), findsOneWidget);
  });

  testWidgets('scales up slightly when the field gains focus', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: SearchAppBar(
            title: '会場一覧',
            controller: controller,
            hintText: '検索...',
          ),
        ),
      ),
    );

    AnimatedScale scaleWidget() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale));

    expect(scaleWidget().scale, 1.0);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(scaleWidget().scale, greaterThan(1.0));
  });
}
