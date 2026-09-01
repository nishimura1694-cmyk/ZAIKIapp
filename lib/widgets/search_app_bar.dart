import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 検索フィールド付きAppBarの共通化。
///
/// `VenueListScreen`（検索欄+絞り込みチップ、高さ110）と
/// `BookingListScreen`（検索欄のみ、高さ66）で高さやパディングが
/// 揃っていなかったため、検索欄部分を66に統一し、絞り込み行は
/// `filterRow` として任意で差し込めるようにする。
///
/// フォーカス時はブランドカラーの枠線とごくわずかな拡大で、
/// 今どこを操作しているかが分かりやすいようにしている。
class SearchAppBar extends StatefulWidget implements PreferredSizeWidget {
  static const double _searchFieldAreaHeight = 66;

  final String title;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final Widget? filterRow;
  final double filterRowHeight;
  final Widget? suffixIcon;
  final List<Widget>? actions;

  const SearchAppBar({
    super.key,
    required this.title,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.filterRow,
    this.filterRowHeight = 45,
    this.suffixIcon,
    this.actions,
  });

  @override
  State<SearchAppBar> createState() => _SearchAppBarState();

  @override
  Size get preferredSize => Size.fromHeight(
    kToolbarHeight +
        _searchFieldAreaHeight +
        (filterRow != null ? filterRowHeight : 0),
  );
}

class _SearchAppBarState extends State<SearchAppBar> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_isFocused == _focusNode.hasFocus) return;
      setState(() => _isFocused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double get _bottomHeight =>
      SearchAppBar._searchFieldAreaHeight +
      (widget.filterRow != null ? widget.filterRowHeight : 0);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(widget.title),
      actions: widget.actions,
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(_bottomHeight),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                height: 50,
                child: AnimatedScale(
                  scale: _isFocused ? 1.02 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: widget.suffixIcon,
                      contentPadding: EdgeInsets.zero,
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppColors.brandOrange,
                          width: 1.5,
                        ),
                      ),
                    ),
                    onChanged: widget.onChanged,
                  ),
                ),
              ),
            ),
            if (widget.filterRow != null)
              SizedBox(height: widget.filterRowHeight, child: widget.filterRow),
          ],
        ),
      ),
    );
  }
}
