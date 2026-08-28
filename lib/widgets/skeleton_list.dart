import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 一覧画面の初回読み込み中に表示する簡易スケルトン。
///
/// スピナーだけよりも「これからカードが並ぶ」ことが伝わり、
/// 体感速度が上がる。
class SkeletonList extends StatefulWidget {
  final int itemCount;

  const SkeletonList({super.key, this.itemCount = 6});

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final opacity = 0.5 + _controller.value * 0.3;
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: widget.itemCount,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => Opacity(
            opacity: opacity,
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.subtleFill,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        );
      },
    );
  }
}
