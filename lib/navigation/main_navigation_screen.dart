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
    const ShiftSplitScreen(),
  );
  late final Widget _venuePage = _wrapInNavigator(
    _venueNavKey,
    VenueListScreen(key: _venueListKey),
  );
  late final Widget _estimatePage = _wrapInNavigator(
    _estimateNavKey,
    const DropboxEstimateTabScreen(),
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
    if (_tabIndex == index) return;

    setState(() {
      _tabIndex = index;
      _markTabAsOpened(index);
    });
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
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: _handleTabChange,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.history), label: '履歴'),
            BottomNavigationBarItem(icon: Icon(Icons.description), label: '見積'),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_today),
              label: 'シフト',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.location_city),
              label: '会場',
            ),
          ],
          selectedItemColor: Color.fromARGB(255, 255, 102, 0),
          unselectedItemColor: Colors.grey,
          backgroundColor: Colors.white,
          type: BottomNavigationBarType.fixed,
        ),
      ),
    );
  }
}
