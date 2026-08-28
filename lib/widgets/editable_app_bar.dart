import 'package:flutter/material.dart';

/// 登録/編集画面（会場登録・予約登録）で重複していたカスタムAppBarの共通化。
///
/// 編集モード時に戻るボタンの隣へ「自動保存中...」/「自動保存」の
/// インジケーターを表示する構成が `AddVenueScreen` と `AddBookingScreen` で
/// ほぼ同一のまま2箇所に実装されていたため、1つのウィジェットにまとめる。
class EditableAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool isEditMode;
  final bool isSaving;
  final VoidCallback? onBack;

  const EditableAppBar({
    super.key,
    required this.title,
    required this.isEditMode,
    required this.isSaving,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final leadingSlotWidth = isEditMode ? 160.0 : 56.0;
    return AppBar(
      automaticallyImplyLeading: false,
      leadingWidth: leadingSlotWidth,
      centerTitle: true,
      titleSpacing: 0,
      leading: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          BackButton(onPressed: onBack),
          if (isEditMode)
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSaving ? Icons.sync : Icons.check_circle_outline,
                        size: 20,
                        color: isSaving ? Colors.orange : Colors.green,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isSaving ? '自動保存中...' : '自動保存',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isSaving ? Colors.orange : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Text(title),
    );
  }
}
