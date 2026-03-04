import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image/image.dart' as img;
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const VenueApp());
}

// --- モデルクラス ---
class PhotoItem {
  final String url;
  final String venueName;
  final String docId;
  final Map<String, dynamic> data;
  PhotoItem(this.url, this.venueName, this.docId, this.data);
}

class VenueApp extends StatelessWidget {
  const VenueApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color brandOrange = Color.fromARGB(255, 255, 102, 0);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZAIKIナビ',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      scrollBehavior: MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        fontFamily: GoogleFonts.mPlus2().fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandOrange,
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
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// --- 共通コンポーネント ---
Widget _detailRow(IconData icon, String label, String? value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: Colors.grey[700]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[500],
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value == null || value.isEmpty ? "-" : value,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// --- メインナビゲーション ---
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  late final PageController _pageController;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _tabIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) {
          if (_tabIndex != i) setState(() => _tabIndex = i);
        },
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [VenueListScreen(), BookingListScreen()],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (index) {
          if (_tabIndex != index) {
            setState(() => _tabIndex = index);
            _pageController.jumpToPage(index);
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.location_city), label: '会場'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '履歴'),
        ],
        selectedItemColor: Color.fromARGB(255, 255, 102, 0),
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}

// --- 会場一覧 ---
class VenueListScreen extends StatefulWidget {
  const VenueListScreen({super.key});
  @override
  State<VenueListScreen> createState() => _VenueListScreenState();
}

class _VenueListScreenState extends State<VenueListScreen> {
  String _searchQuery = "";
  String _selectedBlock = "すべて";

  Future<void> _refreshVenues() async {
    await FirebaseFirestore.instance
        .collection('venues')
        .get(const GetOptions(source: Source.server));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('会場一覧を更新しました')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会場一覧'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: SizedBox(
                  height: 50,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '会場名・部屋名で検索...',
                      prefixIcon: Icon(Icons.search),
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ),
              SizedBox(
                height: 45,
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('blocks')
                      .orderBy('name')
                      .snapshots(),
                  builder: (context, snapshot) {
                    List<String> blocks = ["すべて"];
                    if (snapshot.hasData)
                      blocks.addAll(
                        snapshot.data!.docs.map((d) => d['name'] as String),
                      );
                    return ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: blocks
                          .map(
                            (block) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(block),
                                selected: _selectedBlock == block,
                                onSelected: (selected) =>
                                    setState(() => _selectedBlock = block),
                                selectedColor: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                              ),
                            ),
                          )
                          .toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('venues')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data!.docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final name = (data['name'] ?? '').toString().toLowerCase();
            return name.contains(_searchQuery.toLowerCase()) &&
                (_selectedBlock == "すべて" || data['block'] == _selectedBlock);
          }).toList();
          return RefreshIndicator(
            onRefresh: _refreshVenues,
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              itemCount: docs.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final data = docs[index].data() as Map<String, dynamic>;
                final hasAddress = (data['address'] ?? '')
                    .toString()
                    .isNotEmpty;
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEEEEEE)),
                  ),
                  child: ListTile(
                    title: Text(
                      data['name'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      "エリア: ${data['block'] ?? '-'} / ${data['shopAndRoom'] ?? '-'}",
                    ),
                    trailing: SizedBox(
                      width: 48,
                      child: hasAddress
                          ? IconButton(
                              icon: const Icon(Icons.location_on),
                              color: const Color.fromARGB(255, 255, 102, 0),
                              onPressed: () async {
                                final address = data['address'] ?? '';
                                final String uri =
                                    'https://maps.google.com/?q=${Uri.encodeComponent(address)}';
                                try {
                                  if (await canLaunchUrl(Uri.parse(uri))) {
                                    await launchUrl(
                                      Uri.parse(uri),
                                      mode: LaunchMode.externalApplication,
                                    );
                                  } else {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('地図アプリを開けませんでした'),
                                        ),
                                      );
                                    }
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('エラー: $e')),
                                    );
                                  }
                                }
                              },
                            )
                          : const Icon(Icons.location_on),
                    ),
                    onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.white,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      builder: (_) =>
                          VenueDetailSheet(data: data, docId: docs[index].id),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddVenueScreen()),
        ),
        backgroundColor: const Color.fromARGB(255, 255, 102, 0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('会場を追加'),
      ),
    );
  }
}

// --- 予約履歴一覧 ---
class BookingListScreen extends StatefulWidget {
  const BookingListScreen({super.key});
  @override
  State<BookingListScreen> createState() => _BookingListScreenState();
}

class _BookingListScreenState extends State<BookingListScreen> {
  String _searchQuery = "";
  String? _selectedMonthKey;

  Future<void> _openMapForAddress(String address) async {
    final String uri =
        'https://maps.google.com/?q=${Uri.encodeComponent(address)}';
    try {
      if (await canLaunchUrl(Uri.parse(uri))) {
        await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('地図アプリを開けませんでした')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    }
  }

  Widget _buildBookingLocationButton(Map<String, dynamic> data) {
    final directAddress = (data['venueAddress'] ?? data['address'] ?? '')
        .toString()
        .trim();
    if (directAddress.isNotEmpty) {
      return IconButton(
        icon: const Icon(Icons.location_on),
        color: const Color.fromARGB(255, 255, 102, 0),
        onPressed: () => _openMapForAddress(directAddress),
      );
    }

    final venueId = (data['venueId'] ?? '').toString().trim();
    if (venueId.isEmpty) {
      return const Icon(Icons.location_on, color: Colors.grey);
    }

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('venues')
          .doc(venueId)
          .get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Icon(Icons.location_on, color: Colors.grey);
        }
        final venueData = snapshot.data!.data() as Map<String, dynamic>?;
        final address = (venueData?['address'] ?? '').toString().trim();
        if (address.isEmpty) {
          return const Icon(Icons.location_on, color: Colors.grey);
        }
        return IconButton(
          icon: const Icon(Icons.location_on),
          color: const Color.fromARGB(255, 255, 102, 0),
          onPressed: () => _openMapForAddress(address),
        );
      },
    );
  }

  String _extractMonthKey(String? bookingDate) {
    if (bookingDate == null) return '';
    final normalized = bookingDate.trim().replaceAll('-', '/');
    final match = RegExp(r'^(\d{4})/(\d{1,2})').firstMatch(normalized);
    if (match == null) return '';
    final year = match.group(1)!;
    final month = match.group(2)!.padLeft(2, '0');
    return '$year/$month';
  }

  String _formatMonthChipLabel(String monthKey) {
    final parts = monthKey.split('/');
    if (parts.length != 2) return monthKey;
    return '${parts[0]}年${parts[1]}月';
  }

  Future<void> _refreshBookings() async {
    await FirebaseFirestore.instance
        .collection('bookings')
        .get(const GetOptions(source: Source.server));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('予約履歴を更新しました')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('予約履歴'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: SizedBox(
                  height: 50,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '顧客・会場名で検索...',
                      prefixIcon: Icon(Icons.search),
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
              ),
              SizedBox(
                height: 45,
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('bookings')
                      .orderBy('bookingDate', descending: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final searchedDocs =
                        snapshot.data?.docs.where((doc) {
                          final data = doc.data() as Map<String, dynamic>;
                          final customer = (data['customerName'] ?? '')
                              .toString()
                              .toLowerCase();
                          final venue = (data['venueName'] ?? '')
                              .toString()
                              .toLowerCase();
                          return customer.contains(
                                _searchQuery.toLowerCase(),
                              ) ||
                              venue.contains(_searchQuery.toLowerCase());
                        }).toList() ??
                        [];

                    final monthKeys =
                        searchedDocs
                            .map((doc) {
                              final data = doc.data() as Map<String, dynamic>;
                              return _extractMonthKey(
                                data['bookingDate']?.toString(),
                              );
                            })
                            .where((key) => key.isNotEmpty)
                            .toSet()
                            .toList()
                          ..sort((a, b) => b.compareTo(a));

                    final selectedMonth = monthKeys.contains(_selectedMonthKey)
                        ? _selectedMonthKey
                        : null;

                    return ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        ChoiceChip(
                          label: const Text('すべて'),
                          selected: selectedMonth == null,
                          onSelected: (_) {
                            setState(() => _selectedMonthKey = null);
                          },
                        ),
                        ...monthKeys.map(
                          (monthKey) => Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(_formatMonthChipLabel(monthKey)),
                              selected: selectedMonth == monthKey,
                              onSelected: (_) {
                                setState(() => _selectedMonthKey = monthKey);
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('bookings')
            .orderBy('bookingDate', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final searchedDocs = snapshot.data!.docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final customer = (data['customerName'] ?? '')
                .toString()
                .toLowerCase();
            final venue = (data['venueName'] ?? '').toString().toLowerCase();
            return customer.contains(_searchQuery.toLowerCase()) ||
                venue.contains(_searchQuery.toLowerCase());
          }).toList();

          final monthKeys =
              searchedDocs
                  .map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    return _extractMonthKey(data['bookingDate']?.toString());
                  })
                  .where((key) => key.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort((a, b) => b.compareTo(a));

          final selectedMonth = monthKeys.contains(_selectedMonthKey)
              ? _selectedMonthKey
              : null;

          final docs = selectedMonth == null
              ? searchedDocs
              : searchedDocs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final month = _extractMonthKey(
                    data['bookingDate']?.toString(),
                  );
                  return month == selectedMonth;
                }).toList();

          return RefreshIndicator(
            onRefresh: _refreshBookings,
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              itemCount: docs.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final booking = docs[index];
                final data = booking.data() as Map<String, dynamic>;
                final List urls = data['imageUrls'] ?? [];

                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEEEEEE)),
                  ),
                  child: ListTile(
                    leading: urls.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              urls[0],
                              width: 50,
                              height: 50,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.image_outlined,
                              color: Colors.grey,
                            ),
                          ),
                    title: Text(
                      data['customerName'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      "${data['bookingDate']} / ${data['venueName']}",
                    ),
                    trailing: SizedBox(
                      width: 48,
                      child: _buildBookingLocationButton(data),
                    ),
                    onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.white,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      builder: (_) =>
                          BookingDetailSheet(data: data, docId: booking.id),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddBookingScreen()),
        ),
        backgroundColor: const Color.fromARGB(255, 255, 102, 0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.post_add),
        label: const Text('予約を登録'),
      ),
    );
  }
}

// --- 会場マップビュー ---

// --- 予約詳細シート ---
class BookingDetailSheet extends StatelessWidget {
  final Map<String, dynamic> data;
  final String docId;
  const BookingDetailSheet({
    super.key,
    required this.data,
    required this.docId,
  });

  void _showImageGallery(BuildContext context, List urls, int startIndex) {
    final controller = PageController(initialPage: startIndex);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.9,
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          child: Stack(
            children: [
              PageView.builder(
                controller: controller,
                itemCount: urls.length,
                itemBuilder: (context, i) => InteractiveViewer(
                  child: Image.network(urls[i], fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchURL(BuildContext context, String url) async {
    final Uri uri = Uri.parse(
      url.trim().startsWith('http') ? url.trim() : 'https://${url.trim()}',
    );
    try {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
      }
    }
  }

  Future<void> _deleteBooking(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('削除の確認'),
        content: const Text('この予約履歴を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true && context.mounted) {
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(docId)
          .delete();
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List urls = data['imageUrls'] ?? [];
    final List pdfUrls = data['pdfUrls'] ?? [];
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, controller) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          data['customerName'] ?? '',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AddBookingScreen(
                                    docId: docId,
                                    initialData: data,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: () => _deleteBooking(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _detailRow(Icons.calendar_today, '利用日', data['bookingDate']),
                  _detailRow(
                    Icons.location_on_outlined,
                    '会場',
                    data['venueName'],
                  ),
                  _detailRow(Icons.badge_outlined, '担当者', data['staffName']),
                  if (data['dropboxUrl'] != null &&
                      data['dropboxUrl'].toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: InkWell(
                        onTap: () => _launchURL(context, data['dropboxUrl']),
                        child: _detailRow(
                          Icons.link,
                          'Dropboxリンク (タップで開く)',
                          data['dropboxUrl'],
                        ),
                      ),
                    ),
                  const Divider(height: 32, color: Color(0xFFEEEEEE)),
                  const Text(
                    '写真',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (urls.isEmpty)
                    const Text('なし')
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                      itemCount: urls.length,
                      itemBuilder: (context, i) => GestureDetector(
                        onTap: () => _showImageGallery(context, urls, i),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(urls[i], fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text(
                    'PDF',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (pdfUrls.isEmpty)
                    const Text('なし')
                  else
                    ...pdfUrls.asMap().entries.map(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () =>
                              _launchURL(context, entry.value.toString()),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.picture_as_pdf,
                                  color: Colors.redAccent,
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: Text('PDF ${entry.key + 1}')),
                                const Icon(
                                  Icons.open_in_new,
                                  color: Colors.grey,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  const Text(
                    '備考',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    data['remarks'] ?? 'なし',
                    style: const TextStyle(fontSize: 16, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '引継ぎ事項',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    data['handover'] ?? 'なし',
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.6,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 会場詳細シート ---
class VenueDetailSheet extends StatelessWidget {
  final Map<String, dynamic> data;
  final String docId;
  const VenueDetailSheet({super.key, required this.data, required this.docId});

  Future<void> _deleteVenue(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('会場の削除'),
        content: const Text('この会場情報を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true && context.mounted) {
      await FirebaseFirestore.instance.collection('venues').doc(docId).delete();
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, controller) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          data['name'] ?? '',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AddVenueScreen(
                                    docId: docId,
                                    initialData: data,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                            ),
                            onPressed: () => _deleteVenue(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    data['shopAndRoom'] ?? '',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 32),
                  _detailRow(Icons.grid_view, 'エリア', data['block']),
                  _detailRow(Icons.category, 'カテゴリ', data['category']),
                  _detailRow(Icons.power, '電源仕様', data['power']),
                  _detailRow(
                    Icons.door_front_door,
                    '搬入口・動線',
                    data['loadingPort'],
                  ),
                  _detailRow(Icons.local_parking, '駐車場', data['parking']),
                  _detailRow(Icons.groups, 'キャパシティ', data['capacity']),
                  const SizedBox(height: 20),
                  const Text(
                    'この会場の予約履歴',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('bookings')
                          .where('venueId', isEqualTo: docId)
                          .snapshots(),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Center(
                            child: Text('履歴の取得に失敗しました: ${snap.error}'),
                          );
                        }
                        if (snap.connectionState == ConnectionState.waiting)
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        var docs = snap.data?.docs ?? [];
                        docs.sort((a, b) {
                          final aDate =
                              (a.data() as Map)['bookingDate']?.toString() ??
                              '';
                          final bDate =
                              (b.data() as Map)['bookingDate']?.toString() ??
                              '';
                          return bDate.compareTo(aDate);
                        });
                        if (docs.isEmpty)
                          return const Center(child: Text('履歴がありません'));
                        return ListView.separated(
                          itemCount: docs.length,
                          padding: EdgeInsets.zero,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final b = docs[i].data() as Map<String, dynamic>;
                            final List urls = b['imageUrls'] ?? [];
                            return InkWell(
                              onTap: () {
                                Navigator.pop(context);
                                showModalBottomSheet(
                                  context: context,
                                  isScrollControlled: true,
                                  backgroundColor: Colors.white,
                                  shape: const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(20),
                                    ),
                                  ),
                                  builder: (_) => BookingDetailSheet(
                                    data: b,
                                    docId: docs[i].id,
                                  ),
                                );
                              },
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: urls.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          urls[0],
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          color: Colors.grey[100],
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.image_outlined,
                                          color: Colors.grey,
                                        ),
                                      ),
                                title: Text(
                                  b['customerName'] ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(b['bookingDate'] ?? '-'),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const Divider(height: 40, color: Color(0xFFEEEEEE)),
                  const Text(
                    '備考',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    data['remarks'] ?? 'なし',
                    style: const TextStyle(fontSize: 16, height: 1.6),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 会場登録画面 ---
class AddVenueScreen extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? initialData;
  const AddVenueScreen({super.key, this.docId, this.initialData});
  @override
  State<AddVenueScreen> createState() => _AddVenueScreenState();
}

// マップピッカー画面
class MapPickerScreen extends StatefulWidget {
  final double? initialLat, initialLng;
  const MapPickerScreen({super.key, this.initialLat, this.initialLng});
  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  late LatLng _selectedLocation;

  @override
  void initState() {
    super.initState();
    _selectedLocation = LatLng(
      widget.initialLat ?? 35.6762,
      widget.initialLng ?? 139.6503,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('位置を選択')),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: _selectedLocation,
          zoom: 15,
        ),
        onTap: (location) => setState(() => _selectedLocation = location),
        markers: {
          Marker(
            markerId: const MarkerId('selected'),
            position: _selectedLocation,
          ),
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, _selectedLocation),
        backgroundColor: const Color.fromARGB(255, 255, 102, 0),
        label: const Text('この位置を選択'),
        icon: const Icon(Icons.check),
      ),
    );
  }
}

class _AddVenueScreenState extends State<AddVenueScreen> {
  final Map<String, TextEditingController> _controllers = {
    'name': TextEditingController(),
    'address': TextEditingController(), // 住所追加
    'shopAndRoom': TextEditingController(),
    'loadingPort': TextEditingController(),
    'parking': TextEditingController(),
    'capacity': TextEditingController(),
    'remarks': TextEditingController(),
  };
  String? _selectedBlock, _selectedCategory, _selectedPower;
  bool _isSaving = false;
  // 位置情報関連変数・タイマー・フラグ削除

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      widget.initialData!.forEach((key, val) {
        if (_controllers.containsKey(key))
          _controllers[key]?.text = val.toString();
      });
      _selectedBlock = widget.initialData!['block'];
      _selectedCategory = widget.initialData!['category'];
      _selectedPower = widget.initialData!['power'];
      // 位置情報の初期化削除
    }
  }

  @override
  void dispose() {
    _controllers.forEach((_, controller) => controller.dispose());
    super.dispose();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveVenue() async {
    if (_isSaving) return;

    final name = _controllers['name']?.text.trim() ?? '';
    if (name.isEmpty) {
      _showSnackBar('建物名を入力してください');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final data = {
        for (var e in _controllers.entries) e.key: e.value.text.trim(),
        'block': _selectedBlock,
        'category': _selectedCategory,
        'power': _selectedPower,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.docId == null) {
        data['createdAt'] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance.collection('venues').add(data);
      } else {
        final originalCreatedAt = widget.initialData?['createdAt'];
        if (originalCreatedAt is Timestamp) {
          data['createdAt'] = originalCreatedAt;
        }
        await FirebaseFirestore.instance
            .collection('venues')
            .doc(widget.docId)
            .set(data);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      _showSnackBar('会場情報の保存に失敗しました: $e');
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ドロップダウン管理用メソッド追加
  void _manageItems(String col, String label) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text('$labelの管理'),
        content: SizedBox(
          width: 300,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection(col).snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) return const SizedBox();
              return ListView.builder(
                shrinkWrap: true,
                itemCount: snap.data!.docs.length,
                itemBuilder: (context, index) {
                  final doc = snap.data!.docs[index];
                  return ListTile(
                    title: Text(doc['name']),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () =>
                              _editItem(col, label, doc.id, doc['name']),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete,
                            size: 20,
                            color: Colors.red,
                          ),
                          onPressed: () => _deleteItem(col, doc.id),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addNewItem(col, label);
            },
            child: const Text('新規追加'),
          ),
        ],
      ),
    );
  }

  void _addNewItem(String col, String label) {
    final c = TextEditingController();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text('$labelの追加'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: '名前を入力'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              if (c.text.isNotEmpty) {
                await FirebaseFirestore.instance.collection(col).add({
                  'name': c.text,
                });
                if (mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('追加'),
          ),
        ],
      ),
    );
  }

  void _editItem(String col, String label, String id, String currentName) {
    final c = TextEditingController(text: currentName);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text('$labelの編集'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: '新しい名前'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () async {
              if (c.text.isNotEmpty) {
                await FirebaseFirestore.instance.collection(col).doc(id).update(
                  {'name': c.text},
                );
                if (mounted) Navigator.pop(ctx);
              }
            },
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(String col, String id) async {
    await FirebaseFirestore.instance.collection(col).doc(id).delete();
  }

  Widget _buildDropdown(
    String label,
    String col,
    String? current,
    Function(String?) onChg,
  ) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(col)
          .orderBy('name')
          .snapshots(),
      builder: (context, snap) {
        final items =
            snap.data?.docs.map((d) => d['name'] as String).toList() ?? [];
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: (current != null && items.contains(current))
                    ? current
                    : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: label),
                items: items
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: onChg,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.grey),
              onPressed: () => _manageItems(col, label),
            ),
          ],
        );
      },
    );
  }

  Future<void> _setCurrentLocationAddress() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('位置情報サービスが無効です。')));
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('位置情報の権限がありません。')));
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報の権限が永久に拒否されています。設定から許可してください。')),
        );
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final lat = position.latitude;
      final lng = position.longitude;
      final url =
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&accept-language=ja';
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'zaiki_app/1.0'},
      );
      if (response.statusCode == 200) {
        final rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        dynamic data;
        try {
          data = json.decode(rawBody);
        } on FormatException {
          final sanitized = rawBody.replaceAllMapped(
            RegExp(r'\\u(?![0-9a-fA-F]{4})'),
            (_) => r'\\u',
          );
          data = json.decode(sanitized);
        }
        final address = (data is Map<String, dynamic>)
            ? (data['display_name'] ?? '').toString()
            : '';
        setState(() {
          _controllers['address']?.text = address;
        });
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('現在地の住所を取得しました')));
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('住所の取得に失敗しました')));
      }
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('住所データの形式が不正でした')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('現在地取得エラー: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.docId == null ? '会場の登録' : '会場の編集')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _controllers['name'],
              decoration: const InputDecoration(labelText: '建物名'),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['shopAndRoom'],
              decoration: const InputDecoration(labelText: '部屋/店名'),
            ),
            const SizedBox(height: 15),
            _buildDropdown(
              'エリア',
              'blocks',
              _selectedBlock,
              (v) => setState(() => _selectedBlock = v),
            ),
            const SizedBox(height: 15),
            _buildDropdown(
              'カテゴリ',
              'categories',
              _selectedCategory,
              (v) => setState(() => _selectedCategory = v),
            ),
            const SizedBox(height: 15),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controllers['address'],
                    decoration: const InputDecoration(labelText: '住所'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.my_location, color: Colors.orange),
                  tooltip: '現在地から取得',
                  onPressed: _setCurrentLocationAddress,
                ),
              ],
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['loadingPort'],
              decoration: const InputDecoration(labelText: '搬入口/動線'),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['parking'],
              decoration: const InputDecoration(labelText: '駐車場'),
            ),
            const SizedBox(height: 15),
            _buildDropdown(
              '電源',
              'powers',
              _selectedPower,
              (v) => setState(() => _selectedPower = v),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['capacity'],
              decoration: const InputDecoration(labelText: 'キャパ'),
            ),
            const SizedBox(height: 15),
            // 位置情報欄を削除
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['remarks'],
              decoration: const InputDecoration(labelText: '備考'),
              maxLines: 3,
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveVenue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color.fromARGB(255, 255, 102, 0),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : const Text(
                        '会場情報を保存',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- クラスの外に配置 ---
// compute用: 重い画像処理をバックグラウンドで行う
Future<Uint8List> _processImageIsolate(Map<String, dynamic> params) async {
  final Uint8List bytes = params['bytes'];
  img.Image? image = img.decodeImage(bytes);
  if (image == null) return bytes;

  // リサイズ
  if (image.width > 1024 || image.height > 1024) {
    image = img.copyResize(image, width: 1024);
  }

  // 圧縮 (Quality 75)
  var result = Uint8List.fromList(img.encodeJpg(image, quality: 75));

  // 200KB超えるならさらに落とす
  if (result.lengthInBytes > 200 * 1024) {
    result = Uint8List.fromList(img.encodeJpg(image, quality: 50));
  }
  return result;
}

// --- 予約登録画面 ---
class AddBookingScreen extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? initialData;

  const AddBookingScreen({super.key, this.docId, this.initialData});

  @override
  State<AddBookingScreen> createState() => _AddBookingScreenState();
}

class _PendingImage {
  final Uint8List bytes;

  const _PendingImage({required this.bytes});
}

class _AddBookingScreenState extends State<AddBookingScreen> {
  // --- Controllers ---
  final _customerController = TextEditingController();
  final _staffController = TextEditingController();
  final _dateController = TextEditingController();
  final _remarksController = TextEditingController();
  final _handoverController = TextEditingController();
  final _dropboxController = TextEditingController();
  final _venueSearchController = TextEditingController();

  // --- State Variables ---
  String? _selectedVenueId, _selectedVenueName;
  final List<_PendingImage> _newImages = []; // 新しく選択された画像
  List<String> _existingUrls = []; // すでにFirestoreにある画像
  List<String> _existingPdfUrls = []; // すでにFirestoreにあるPDF
  bool _isUploading = false;
  bool _showVenueList = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      final d = widget.initialData!;
      _customerController.text = d['customerName'] ?? '';
      _staffController.text = d['staffName'] ?? '';
      _dateController.text = d['bookingDate'] ?? '';
      _remarksController.text = d['remarks'] ?? '';
      _handoverController.text = d['handover'] ?? '';
      _dropboxController.text = d['dropboxUrl'] ?? '';
      _selectedVenueId = d['venueId'];
      _selectedVenueName = d['venueName'];
      _venueSearchController.text = d['venueName'] ?? '';
      _existingUrls = List<String>.from(d['imageUrls'] ?? []);
      _existingPdfUrls = List<String>.from(d['pdfUrls'] ?? []);
    }
  }

  // --- Logic: Venue Management ---

  Future<void> _quickRegisterVenue() async {
    final name = _venueSearchController.text.trim();
    if (name.isEmpty) return;

    setState(() => _isUploading = true);
    try {
      final docRef = await FirebaseFirestore.instance.collection('venues').add({
        'name': name,
        'address': '',
        'shopAndRoom': '',
        'loadingPort': '',
        'parking': '',
        'capacity': '',
        'remarks': '',
        'block': null,
        'category': null,
        'power': null,
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      setState(() {
        _selectedVenueId = docRef.id;
        _selectedVenueName = name;
        _showVenueList = false;
      });
      _showSnackBar('新規会場として登録しました');
    } catch (e) {
      _showSnackBar('会場登録に失敗しました: $e');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  // --- Logic: Image Management ---

  Future<void> _pickImages() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty) return;

    final pendingImages = <_PendingImage>[];
    for (final file in picked) {
      try {
        final bytes = await file.readAsBytes();
        pendingImages.add(_PendingImage(bytes: bytes));
      } catch (e) {
        debugPrint('Failed to read picked image: $e');
      }
    }

    if (pendingImages.isEmpty) {
      _showSnackBar('画像の読み込みに失敗しました');
      return;
    }

    setState(() => _newImages.addAll(pendingImages));
  }

  // --- Logic: Save ---

  Future<void> _save() async {
    // 1. 最初に即座にフラグを立ててボタンを無効化
    setState(() {
      _isUploading = true;
    });

    // 2. 必須チェック
    if (_selectedVenueId == null || _customerController.text.isEmpty) {
      _showSnackBar('会場と顧客名を入力してください');
      setState(() => _isUploading = false);
      return;
    }

    // 3. 描画を1フレーム待機（これで確実にぐるぐるが表示される）
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      // 4. 画像の圧縮とアップロード
      // _uploadImagesの中で compute を使うよう修正
      final List<String> newUrls = await _uploadImages();

      // 5. Firestoreへの保存
      await _saveToFirestore(newUrls);

      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Error during save: $e');
      _showSnackBar('保存失敗: $e');
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<List<String>> _uploadImages() async {
    if (_newImages.isEmpty) return [];

    final storage = FirebaseStorage.instance;
    final List<String> uploadedUrls = [];

    for (final image in _newImages) {
      final originalBytes = image.bytes;
      final compressedBytes = await compute(_processImageIsolate, {
        'bytes': originalBytes,
      });
      final fileName =
          'bookings/${DateTime.now().millisecondsSinceEpoch}_${uploadedUrls.length}.jpg';

      final ref = storage.ref().child(fileName);
      await ref.putData(
        compressedBytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final downloadUrl = await ref.getDownloadURL();
      uploadedUrls.add(downloadUrl);
    }

    return uploadedUrls;
  }

  Future<void> _saveToFirestore(List<String> newUrls) async {
    final venueNameFromInput = _venueSearchController.text.trim();
    var venueName = (_selectedVenueName ?? venueNameFromInput).trim();
    final dropboxUrl = _dropboxController.text.trim();

    if (dropboxUrl.isNotEmpty && !dropboxUrl.startsWith('https://')) {
      throw FormatException('Dropboxリンクは https:// で始まるURLを入力してください');
    }

    if (venueName.isEmpty && _selectedVenueId != null) {
      final venueDoc = await FirebaseFirestore.instance
          .collection('venues')
          .doc(_selectedVenueId)
          .get();
      venueName = (venueDoc.data()?['name'] ?? '').toString();
    }

    final data = {
      'customerName': _customerController.text.trim(),
      'staffName': _staffController.text.trim(),
      'bookingDate': _dateController.text.trim(),
      'remarks': _remarksController.text.trim(),
      'handover': _handoverController.text.trim(),
      'dropboxUrl': dropboxUrl.isEmpty ? null : dropboxUrl,
      'venueId': _selectedVenueId,
      'venueName': venueName,
      'imageUrls': [..._existingUrls, ...newUrls],
      'pdfUrls': _existingPdfUrls,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (widget.docId == null) {
      await FirebaseFirestore.instance.collection('bookings').add({
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      final existingCreatedAt = widget.initialData?['createdAt'];
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.docId)
          .set({
            ...data,
            'createdAt': existingCreatedAt is Timestamp
                ? existingCreatedAt
                : null,
          });
    }
  }

  // --- UI Helpers ---

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.docId == null ? '予約の登録' : '予約の編集'),
        elevation: 0,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildVenueSection(),
                const SizedBox(height: 20),
                _buildTextField(_customerController, '顧客名（案件名）'),
                _buildTextField(_staffController, '担当者'),
                _buildDatePicker(),
                _buildTextField(_dropboxController, 'Dropboxリンク'),
                const SizedBox(height: 24),
                _buildImageSection(),
                const SizedBox(height: 24),
                _buildTextField(_remarksController, '備考', maxLines: 3),
                _buildTextField(
                  _handoverController,
                  '引継ぎ事項',
                  maxLines: 3,
                  isUrgent: true,
                ),
                const SizedBox(height: 40),
                _buildSaveButton(),
                const SizedBox(height: 100),
              ],
            ),
          ),
          if (_isUploading) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  // --- Build Methods ---

  Widget _buildVenueSection() {
    return Column(
      children: [
        TextField(
          controller: _venueSearchController,
          decoration: InputDecoration(
            labelText: '会場・部屋/店名',
            prefixIcon: const Icon(Icons.search),
            suffixIcon:
                _selectedVenueId == null &&
                    _venueSearchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.add_circle, color: Colors.orange),
                    onPressed: _quickRegisterVenue,
                  )
                : null,
          ),
          onChanged: (v) {
            setState(() {
              _showVenueList = true;
              final normalizedInput = v.trim();
              final normalizedSelected = (_selectedVenueName ?? '').trim();
              if (normalizedInput != normalizedSelected) {
                _selectedVenueId = null;
                _selectedVenueName = null;
              }
            });
          },
        ),
        if (_showVenueList)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('venues')
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) return const LinearProgressIndicator();
                final query = _venueSearchController.text.toLowerCase();
                final filtered = snap.data!.docs.where((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final name = (data['name'] ?? '').toString().toLowerCase();
                  final shopAndRoom = (data['shopAndRoom'] ?? '')
                      .toString()
                      .toLowerCase();
                  return name.contains(query) || shopAndRoom.contains(query);
                }).toList();

                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final data = filtered[i].data() as Map<String, dynamic>;
                    final venueName = (data['name'] ?? '').toString();
                    final shopAndRoom = (data['shopAndRoom'] ?? '').toString();
                    return ListTile(
                      title: Text(venueName),
                      subtitle: Text(shopAndRoom.isEmpty ? '-' : shopAndRoom),
                      onTap: () => setState(() {
                        _selectedVenueId = filtered[i].id;
                        _selectedVenueName = venueName;
                        _venueSearchController.text = venueName;
                        _showVenueList = false;
                      }),
                    );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
    bool isUrgent = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: isUrgent
              ? const TextStyle(color: Colors.redAccent)
              : null,
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextField(
        controller: _dateController,
        readOnly: true,
        decoration: const InputDecoration(
          labelText: '利用日',
          prefixIcon: Icon(Icons.calendar_today),
        ),
        onTap: () async {
          DateTime? initialDate;
          final currentValue = _dateController.text.trim();
          if (currentValue.isNotEmpty) {
            try {
              initialDate = DateFormat('yyyy/MM/dd').parseStrict(currentValue);
            } catch (_) {}
          }
          initialDate ??= DateTime.now();

          DateTime tempSelectedDate = initialDate;
          DateTime? lastTappedDate;
          DateTime? lastTappedAt;

          final d = await showDialog<DateTime>(
            context: context,
            builder: (dialogContext) {
              return Dialog(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: SizedBox(
                  width: 280,
                  child: StatefulBuilder(
                    builder: (context, setDialogState) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CalendarDatePicker(
                            initialDate: tempSelectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                            currentDate: DateTime.now(),
                            onDateChanged: (value) {
                              final now = DateTime.now();
                              final isDoubleTap =
                                  lastTappedDate != null &&
                                  lastTappedAt != null &&
                                  DateUtils.isSameDay(lastTappedDate, value) &&
                                  now
                                          .difference(lastTappedAt!)
                                          .inMilliseconds <=
                                      500;

                              setDialogState(() => tempSelectedDate = value);
                              lastTappedDate = value;
                              lastTappedAt = now;

                              if (isDoubleTap) {
                                Navigator.pop(dialogContext, value);
                              }
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext),
                                child: const Text('キャンセル'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(
                                  dialogContext,
                                  tempSelectedDate,
                                ),
                                child: const Text('決定'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          );
          if (d != null) {
            setState(
              () => _dateController.text = DateFormat('yyyy/MM/dd').format(d),
            );
          }
        },
      ),
    );
  }

  Widget _buildImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('写真', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // 既存画像
            ..._existingUrls.map(
              (url) => _buildImageTile(
                url: url,
                onRemove: () {
                  setState(() => _existingUrls.remove(url));
                },
              ),
            ),
            // 新規画像
            ..._newImages.map(
              (image) => _buildImageTile(
                bytes: image.bytes,
                onRemove: () {
                  setState(() => _newImages.remove(image));
                },
              ),
            ),
            // 追加ボタン
            _buildAddImageButton(),
          ],
        ),
      ],
    );
  }

  Widget _buildImageTile({
    String? url,
    Uint8List? bytes,
    required VoidCallback onRemove,
  }) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 80,
            height: 80,
            child: url != null
                ? Image.network(url, fit: BoxFit.cover)
                : bytes != null
                ? Image.memory(bytes, fit: BoxFit.cover)
                : const SizedBox.shrink(),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: IconButton(
            icon: const Icon(Icons.cancel, color: Colors.red, size: 20),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }

  Widget _buildAddImageButton() {
    return GestureDetector(
      onTap: _pickImages,
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.add_a_photo, color: Colors.grey),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        // アップロード中はボタン自体を無効化（連打防止）
        onPressed: _isUploading ? null : _save,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange[800],
          disabledBackgroundColor: Colors.orange[200], // 無効化時の色
        ),
        child: _isUploading
            ? const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              )
            : const Text(
                '予約内容を保存',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black26,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}
