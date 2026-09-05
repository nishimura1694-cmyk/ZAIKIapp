part of '../main.dart';

// --- メインナビゲーション ---
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _tabIndex = 0;
  bool _hasOpenedShiftTab = false;
  bool _hasOpenedVenueTab = false;
  bool _hasOpenedEstimateTab = false;
  final GlobalKey<_VenueListScreenState> _venueListKey =
      GlobalKey<_VenueListScreenState>();
  final GlobalKey<_BookingListScreenState> _bookingListKey =
      GlobalKey<_BookingListScreenState>();
  final GlobalKey<_ShiftSplitScreenState> _shiftSplitKey =
      GlobalKey<_ShiftSplitScreenState>();
  final GlobalKey<_DropboxEstimateTabScreenState> _estimateTabKey =
      GlobalKey<_DropboxEstimateTabScreenState>();
  final GlobalKey<NavigatorState> _bookingNavKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _shiftNavKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _venueNavKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _estimateNavKey = GlobalKey<NavigatorState>();

  Widget _wrapInNavigator(GlobalKey<NavigatorState> navKey, Widget home) {
    return Navigator(
      key: navKey,
      onGenerateRoute: (settings) =>
          MaterialPageRoute(builder: (_) => home, settings: settings),
    );
  }

  late final Widget _bookingPage = _wrapInNavigator(
    _bookingNavKey,
    BookingListScreen(key: _bookingListKey),
  );
  late final Widget _shiftPage = _wrapInNavigator(
    _shiftNavKey,
    ShiftSplitScreen(key: _shiftSplitKey),
  );
  late final Widget _venuePage = _wrapInNavigator(
    _venueNavKey,
    VenueListScreen(key: _venueListKey),
  );
  late final Widget _estimatePage = _wrapInNavigator(
    _estimateNavKey,
    DropboxEstimateTabScreen(key: _estimateTabKey),
  );

  List<GlobalKey<NavigatorState>> get _navKeys => [
    _bookingNavKey,
    _estimateNavKey,
    _shiftNavKey,
    _venueNavKey,
  ];

  void _markTabAsOpened(int index) {
    if (index == 1) _hasOpenedEstimateTab = true;
    if (index == 2) _hasOpenedShiftTab = true;
    if (index == 3) _hasOpenedVenueTab = true;
  }

  void _handleTabChange(int index) {
    if (_tabIndex == index) {
      _resetTabToInitialState(index);
      return;
    }

    setState(() {
      _tabIndex = index;
      _markTabAsOpened(index);
    });
  }

  /// 選択中のタブをもう一度押した際の挙動。
  /// サブページを開いている場合はルートに戻るだけに留め、
  /// 既にルート表示中の場合のみ検索・絞り込み・スクロール位置を初期化する。
  void _resetTabToInitialState(int index) {
    final navState = _navKeys[index].currentState;
    if (navState?.canPop() ?? false) {
      navState?.popUntil((route) => route.isFirst);
      return;
    }
    switch (index) {
      case 0:
        _bookingListKey.currentState?.resetToInitialState();
        break;
      case 1:
        _estimateTabKey.currentState?.resetToInitialState();
        break;
      case 2:
        _shiftSplitKey.currentState?.resetToInitialState();
        break;
      case 3:
        _venueListKey.currentState?.resetToInitialState();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final navKey = _navKeys[_tabIndex];
        if (navKey.currentState?.canPop() == true) {
          navKey.currentState!.pop();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tabIndex,
          children: [
            _bookingPage,
            _hasOpenedEstimateTab ? _estimatePage : const SizedBox.shrink(),
            _hasOpenedShiftTab ? _shiftPage : const SizedBox.shrink(),
            _hasOpenedVenueTab ? _venuePage : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: _handleTabChange,
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.brandOrange.withValues(alpha: 0.16),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: '履歴',
            ),
            NavigationDestination(
              icon: Icon(Icons.description_outlined),
              selectedIcon: Icon(Icons.description),
              label: '見積',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_today),
              label: 'シフト',
            ),
            NavigationDestination(
              icon: Icon(Icons.location_city_outlined),
              selectedIcon: Icon(Icons.location_city),
              label: '会場',
            ),
          ],
        ),
      ),
    );
  }
}
