import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaiki_app/widgets/editable_app_bar.dart';

void main() {
  testWidgets('shows only the back button when not in edit mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: EditableAppBar(
            title: '会場の登録',
            isEditMode: false,
            isSaving: false,
          ),
        ),
      ),
    );

    expect(find.text('会場の登録'), findsOneWidget);
    expect(find.text('自動保存'), findsNothing);
    expect(find.text('自動保存中...'), findsNothing);
  });

  testWidgets('shows the saved indicator in edit mode', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: EditableAppBar(
            title: '会場の編集',
            isEditMode: true,
            isSaving: false,
          ),
        ),
      ),
    );

    expect(find.text('自動保存'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('shows the saving indicator while isSaving is true', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: EditableAppBar(
            title: '会場の編集',
            isEditMode: true,
            isSaving: true,
          ),
        ),
      ),
    );

    expect(find.text('自動保存中...'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
  });
}
