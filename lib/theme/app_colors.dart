import 'package:flutter/material.dart';

/// アプリ全体で使う色の一元定義。
///
/// Claudeのブランドに寄せた、暖色系のクリーム背景＋テラコッタ系
/// オレンジのパレット。以前は `Color.fromARGB(255, 255, 102, 0)` や
/// `#EEEEEE` のような単色オレンジ・冷色グレーのリテラルが画面ごとに
/// 再宣言されていたものをここに集約している。
class AppColors {
  AppColors._();

  /// Claudeのアクセントカラーに近いテラコッタ/クレイオレンジ。
  static const Color brandOrange = Color(0xFFD97757);
  static const Color brandOrangeDark = Color(0xFFBD5D3A);

  /// ページ全体の背景に使う、暖色寄りのクリーム色。
  static const Color background = Color(0xFFF7F4EC);

  /// カード・入力欄など「背景の上に浮く面」に使う白（純白よりやや暖色）。
  static const Color surface = Color(0xFFFFFEFB);

  static const Color dividerGrey = Color(0xFFE6E1D6);
  static const Color subtleFill = Color(0xFFF0ECE1);
  static const Color textPrimary = Color(0xFF3D3929);

  /// 補足テキスト・非活性アイコンなどに使う、暖色寄りのミュートグレー。
  static const Color textSecondary = Color(0xFF8A8375);

  /// 削除・エラーなど「危険」を示す色。Material標準の赤ではなく、
  /// テラコッタ寄りの暖色パレットに馴染むよう少し落ち着かせている。
  static const Color danger = Color(0xFFC4483A);
  static const Color dangerBackground = Color(0xFFF5E1DC);
}

/// カード等の「状態」を表す背景色・枠線色のペア。
///
/// 画面ごとに `#E3F2FD`/`#64B5F6` のような組み合わせが
/// コピペされていたものを共通化する。
class StatusPalette {
  final Color background;
  final Color border;

  const StatusPalette({required this.background, required this.border});

  static const StatusPalette neutral = StatusPalette(
    background: AppColors.surface,
    border: AppColors.dividerGrey,
  );

  /// 「本日」を示す強調色。ブランドカラーのテラコッタを薄く敷く。
  static const StatusPalette today = StatusPalette(
    background: Color(0xFFF5E3DA),
    border: AppColors.brandOrange,
  );

  /// 「明日」を示す強調色。テラコッタより控えめな、暖色系のサンド/ゴールド。
  static const StatusPalette tomorrow = StatusPalette(
    background: Color(0xFFF3E8CC),
    border: Color(0xFFC9A227),
  );

  static const StatusPalette grey = StatusPalette(
    background: AppColors.subtleFill,
    border: AppColors.dividerGrey,
  );

  /// 「本日/明日/それ以外」で色分けするカード群（予約一覧のCSV表示・
  /// シフト表・日付抽出ビューなど）で共通して使う配色の解決ロジック。
  ///
  /// これまで同じ判定・同じ色リテラルが画面ごとに個別実装されていた。
  static StatusPalette forDateGroup({
    required bool isToday,
    required bool isTomorrow,
    StatusPalette otherwise = neutral,
  }) {
    if (isToday) return today;
    if (isTomorrow) return tomorrow;
    return otherwise;
  }
}
