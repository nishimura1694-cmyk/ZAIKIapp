import 'package:flutter/material.dart';

/// 一覧画面の「データがありません」表示を統一するためのウィジェット。
///
/// 既存コードでは画面ごとに文言・スタイルがばらばらな `Text` が
/// 直接置かれていたため、アイコン付きの共通表現に揃える。
class EmptyStateView extends StatelessWidget {
  final String message;
  final IconData icon;
  final Widget? action;

  const EmptyStateView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 14),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// 一覧画面のローディング表示を統一するためのウィジェット。
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}
