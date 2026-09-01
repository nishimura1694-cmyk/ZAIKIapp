import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// アプリ共通のボトムシート表示ヘルパー。
///
/// 会場詳細・予約詳細などで同じ見た目（背景色・上角丸20px）を
/// 個別に書いていたのをまとめ、既定より少しゆっくり・滑らかな
/// カーブ（easeOutCubic/easeInCubic）で開閉するようにしている。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 320),
      reverseDuration: Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
    builder: builder,
  );
}
