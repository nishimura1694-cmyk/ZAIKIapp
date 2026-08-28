import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/theme/app_colors.dart';
import 'package:zaiki_app/widgets/section_card.dart';

void main() {
  testWidgets('SectionCard uses the neutral palette by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SectionCard(child: Text('会場A'))),
      ),
    );

    expect(find.text('会場A'), findsOneWidget);
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, StatusPalette.neutral.background);
  });

  testWidgets('SectionCard applies the given palette', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SectionCard(
            palette: StatusPalette.blue,
            child: Text('選択中'),
          ),
        ),
      ),
    );

    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, StatusPalette.blue.background);
  });

  testWidgets('SectionCard fires onTap when tapped', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SectionCard(
            onTap: () => tapped = true,
            child: const Text('会場B'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('会場B'));
    expect(tapped, isTrue);
  });
}
