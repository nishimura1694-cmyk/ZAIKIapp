import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 一覧画面のカード/リスト項目を統一するためのラッパー。
///
/// 既存コードでは `Card`＋`ListTile`／`Container`+`BoxDecoration`＋`ListTile`／
/// 素の `ListTile` の3種類が画面ごとに混在し、角丸(6/10/12px)や
/// 枠線色(`#EEEEEE`/`#DADADA`)もばらついていた。これを角丸12px・
/// 標準の枠線色に統一し、`palette` で状態色（選択中・注意など）を
/// 差し込めるようにする。
class SectionCard extends StatelessWidget {
  final Widget child;
  final StatusPalette palette;
  final VoidCallback? onTap;

  const SectionCard({
    super.key,
    required this.child,
    this.palette = StatusPalette.neutral,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: child,
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: content,
      ),
    );
  }
}
