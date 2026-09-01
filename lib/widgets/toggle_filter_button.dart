import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// 一覧画面の「表示/非表示」を切り替えるトグル型ボタン。
///
/// 予約履歴の「先の予約」ボタンで使われていたスタイル（非アクティブ時は
/// グレーの枠線、アクティブ時は枠線・文字色・背景色がブランドカラーに
/// 変わる）を他の画面でも再利用できるようにしたもの。
class ToggleFilterButton extends StatelessWidget {
  final bool isActive;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String activeLabel;
  final VoidCallback onPressed;

  const ToggleFilterButton({
    super.key,
    required this.isActive,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.activeLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: isActive ? AppColors.brandOrange : AppColors.dividerGrey,
        ),
        foregroundColor: isActive ? AppColors.brandOrange : Colors.black54,
        backgroundColor: isActive
            ? AppColors.brandOrange.withValues(alpha: 0.12)
            : null,
      ),
      icon: Icon(isActive ? activeIcon : icon),
      label: Text(isActive ? activeLabel : label),
    );
  }
}
