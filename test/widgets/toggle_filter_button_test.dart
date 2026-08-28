import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/toggle_filter_button.dart';

void main() {
  testWidgets('shows the inactive label and icon by default', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToggleFilterButton(
            isActive: false,
            icon: Icons.event_note_outlined,
            activeIcon: Icons.visibility_off_rounded,
            label: '先の予約',
            activeLabel: '先の予約を隠す',
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.text('先の予約'), findsOneWidget);
    expect(find.byIcon(Icons.event_note_outlined), findsOneWidget);
  });

  testWidgets('shows the active label and icon when active', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToggleFilterButton(
            isActive: true,
            icon: Icons.event_note_outlined,
            activeIcon: Icons.visibility_off_rounded,
            label: '先の予約',
            activeLabel: '先の予約を隠す',
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.text('先の予約を隠す'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
  });

  testWidgets('fires onPressed when tapped', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToggleFilterButton(
            isActive: false,
            icon: Icons.event_note_outlined,
            activeIcon: Icons.visibility_off_rounded,
            label: '先の予約',
            activeLabel: '先の予約を隠す',
            onPressed: () => tapped = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(OutlinedButton));
    expect(tapped, isTrue);
  });
}
