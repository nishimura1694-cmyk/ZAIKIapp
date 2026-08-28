import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// アプリ全体のテーマ定義。
///
/// `VenueApp` に直接書かれていた `ThemeData` をそのままここへ移す
/// （見た目は既存の値をそのまま踏襲、追加の変更はしない）。
///
/// 画面ごとに再宣言されている `ElevatedButton.styleFrom` の統一は、
/// ここでテーマとして一括変更するとスタイル未指定のボタン（ダイアログの
/// アクションボタンなど）の見た目まで意図せず変わってしまうため、
/// 個々の画面を移行するタイミングで対応する。
class AppTheme {
  AppTheme._();

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.white,
      fontFamily: GoogleFonts.mPlus2().fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.brandOrange,
        surface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
        iconTheme: IconThemeData(color: Colors.black),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      datePickerTheme: const DatePickerThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.black87,
        selectionColor: Color(0xFFDDDDDD),
        selectionHandleColor: Colors.black87,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.subtleFill,
        isDense: true,
        alignLabelWithHint: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}
