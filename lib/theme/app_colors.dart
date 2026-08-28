import 'package:flutter/material.dart';

/// アプリ全体で使う色の一元定義。
///
/// これまで `Color.fromARGB(255, 255, 102, 0)` や `#EEEEEE` のような
/// リテラルが画面ごとに再宣言されていたものを集約する。
class AppColors {
  AppColors._();

  static const Color brandOrange = Color.fromARGB(255, 255, 102, 0);
  static const Color dividerGrey = Color(0xFFEEEEEE);
  static const Color subtleFill = Color(0xFFF5F5F5);
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
    background: Colors.white,
    border: AppColors.dividerGrey,
  );

  static const StatusPalette blue = StatusPalette(
    background: Color(0xFFE3F2FD),
    border: Color(0xFF64B5F6),
  );

  static const StatusPalette yellow = StatusPalette(
    background: Color(0xFFFFF59D),
    border: Color(0xFFFFE082),
  );

  static const StatusPalette grey = StatusPalette(
    background: Color(0xFFF3F3F3),
    border: Color(0xFFDADADA),
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
    if (isToday) return blue;
    if (isTomorrow) return yellow;
    return otherwise;
  }
}
