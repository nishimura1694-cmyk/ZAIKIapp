import 'package:flutter/material.dart';

/// 検索フィールド付きAppBarの共通化。
///
/// `VenueListScreen`（検索欄+絞り込みチップ、高さ110）と
/// `BookingListScreen`（検索欄のみ、高さ66）で高さやパディングが
/// 揃っていなかったため、検索欄部分を66に統一し、絞り込み行は
/// `filterRow` として任意で差し込めるようにする。
class SearchAppBar extends StatelessWidget implements PreferredSizeWidget {
  static const double _searchFieldAreaHeight = 66;

  final String title;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final Widget? filterRow;
  final double filterRowHeight;

  const SearchAppBar({
    super.key,
    required this.title,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.filterRow,
    this.filterRowHeight = 45,
  });

  double get _bottomHeight =>
      _searchFieldAreaHeight + (filterRow != null ? filterRowHeight : 0);

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + _bottomHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(_bottomHeight),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                height: 50,
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: hintText,
                    prefixIcon: const Icon(Icons.search),
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: onChanged,
                ),
              ),
            ),
            if (filterRow != null)
              SizedBox(height: filterRowHeight, child: filterRow),
          ],
        ),
      ),
    );
  }
}
