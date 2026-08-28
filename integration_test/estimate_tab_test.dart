import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zaiki_app/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('見積タブに登録済みの月次データが表示される', (tester) async {
    await tester.pumpWidget(const VenueAppBootstrap());

    // Firebase初期化とホーム画面(履歴タブ)の初期読み込みを待つ。
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('見積'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d != null)
        .toList();
    // ignore: avoid_print
    print('ESTIMATE_TAB_TEXTS: $texts');

    expect(find.text('登録済みの見積データがありません'), findsNothing);
    expect(find.textContaining('登録済み見積データ'), findsOneWidget);
    expect(find.textContaining('1004加納さま'), findsOneWidget);
  });
}
