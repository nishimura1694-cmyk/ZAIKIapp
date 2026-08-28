import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

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
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
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

/// キャッシュが無く、初回読み込み自体が失敗した場合の全画面エラー表示。
///
/// 以前は`StreamBuilder`が`snapshot.hasError`を見ておらず、通信エラー時に
/// 「該当なし」の空表示にすり替わってユーザーが失敗に気づけなかったため導入。
class ErrorRetryView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorRetryView({
    super.key,
    this.message = 'データの取得に失敗しました',
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off,
              size: 40,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }
}

/// キャッシュ済みの一覧を表示しつつ、裏側の再取得が失敗したことを
/// 知らせる帯。一覧自体は消さず、古いデータかもしれないことだけを伝える。
class ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorBanner({
    super.key,
    this.message = '最新の情報を取得できませんでした(表示中の内容は古い可能性があります)',
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.dangerBackground,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('再試行'),
          ),
        ],
      ),
    );
  }
}
