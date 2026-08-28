/// 画面共通の余白スケール。
///
/// 既存コードでは 4/8/10/12/16/20/24 が場当たり的に使われていたため、
/// 新規・移行後のコードはこのスケールから選ぶ。
class AppSpacing {
  AppSpacing._();

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
}
