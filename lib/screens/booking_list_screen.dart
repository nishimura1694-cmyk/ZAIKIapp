part of '../main.dart';

// --- 予約履歴一覧 ---
class BookingListScreen extends StatefulWidget {
  const BookingListScreen({super.key});
  @override
  State<BookingListScreen> createState() => _BookingListScreenState();
}

class _BookingListScreenState extends State<BookingListScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";
  String? _selectedMonthKey;
  final Map<String, Future<String?>> _venueAddressFutureCache = {};
  final Map<String, bool> _retrospectiveCheckedOverrides = {};
  int _bookingFetchLimit = _bookingPageSize;
  bool _showHiddenReservations = false;
  List<_SearchResultDocument> _lastBookingDocs = const [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final value = _searchController.text;
    if (_searchQuery == value) return;
    setState(() => _searchQuery = value);
  }

  void clearSearch() {
    if (_searchController.text.isEmpty && _searchQuery.isEmpty) return;
    _searchController.clear();
    if (!mounted) return;
    setState(() => _searchQuery = '');
  }

  void _loadMoreBookings() {
    setState(() {
      _bookingFetchLimit += _bookingPageSize;
    });
  }

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

  Future<String?> _fetchVenueAddress(String venueId) {
    return _venueAddressFutureCache.putIfAbsent(venueId, () async {
      final snapshot = await FirebaseFirestore.instance
          .collection('venues')
          .doc(venueId)
          .get();
      final venueData = snapshot.data();
      final address = (venueData?['address'] ?? '').toString().trim();
      return address.isEmpty ? null : address;
    });
  }

  Widget _buildBookingLocationButton(Map<String, dynamic> data) {
    final directAddress = (data['venueAddress'] ?? data['address'] ?? '')
        .toString()
        .trim();
    if (directAddress.isNotEmpty) {
      return IconButton(
        icon: const Icon(Icons.location_on),
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        splashRadius: 18,
        visualDensity: VisualDensity.compact,
        color: AppColors.brandOrange,
        tooltip: '地図アプリで開く',
        onPressed: () => _openMapForAddress(directAddress),
      );
    }

    final venueId = (data['venueId'] ?? '').toString().trim();
    if (venueId.isEmpty) {
      return const SizedBox(
        width: 32,
        child: Icon(Icons.location_on, color: Colors.grey, size: 20),
      );
    }

    return FutureBuilder<String?>(
      future: _fetchVenueAddress(venueId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 32,
            child: Icon(Icons.location_on, color: Colors.grey, size: 20),
          );
        }
        final address = snapshot.data;
        if (address == null || address.isEmpty) {
          return const SizedBox(
            width: 32,
            child: Icon(Icons.location_on, color: Colors.grey, size: 20),
          );
        }
        return IconButton(
          icon: const Icon(Icons.location_on),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          splashRadius: 18,
          visualDensity: VisualDensity.compact,
          color: AppColors.brandOrange,
          tooltip: '地図アプリで開く',
          onPressed: () => _openMapForAddress(address),
        );
      },
    );
  }

  Widget _buildBookingEstimateButton(Map<String, dynamic> data) {
    final customerName = (data['customerName'] ?? '').toString().trim();
    final venueName = (data['venueName'] ?? '').toString().trim();
    final query = customerName.isNotEmpty ? customerName : venueName;
    final bookingDate = (data['bookingDate'] ?? '').toString().trim();
    return IconButton(
      icon: const Icon(Icons.description_outlined),
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      splashRadius: 18,
      visualDensity: VisualDensity.compact,
      color: AppColors.brandOrange,
      tooltip: '見積を確認',
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DropboxEstimateTabScreen(
            initialSearchQuery: query.isEmpty ? null : query,
            initialDeliveryDate: bookingDate.isEmpty ? null : bookingDate,
          ),
        ),
      ),
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
    clearSearch();
    _invalidateSearchQueryCache(namespace: 'bookings');
    await FirebaseFirestore.instance
        .collection('bookings')
        .get(const GetOptions(source: Source.server));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('予約履歴を更新しました')));
  }

  Future<void> _setRetrospectiveChecked({
    required String bookingId,
    required bool nextValue,
    required bool previousValue,
  }) async {
    if (mounted) {
      setState(() {
        _retrospectiveCheckedOverrides[bookingId] = nextValue;
      });
    }

    try {
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .update({
            'retrospectiveChecked': nextValue,
            'updatedAt': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _retrospectiveCheckedOverrides[bookingId] = previousValue;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('振り返りチェックの更新に失敗しました: $e')));
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final searchQuery = _searchQuery.trim();
    final isSearching = searchQuery.isNotEmpty;
    final now = DateTime.now();
    final effectiveBookingFetchLimit = _showHiddenReservations
        ? _bookingFetchLimit + _bookingPageSize * 5
        : _bookingFetchLimit;
    final bookingStream = _buildIndexedSearchStream(
      cacheNamespace: 'bookings',
      collection: FirebaseFirestore.instance.collection('bookings'),
      searchQuery: searchQuery,
      idleLimit: effectiveBookingFetchLimit,
      searchLimit: _bookingSearchCandidateLimit,
      fallbackQueryBuilder: (collection, limit) =>
          collection.orderBy('bookingDate', descending: true).limit(limit),
    );

    return Scaffold(
      appBar: SearchAppBar(
        title: '予約履歴',
        controller: _searchController,
        hintText: '顧客・会場名で検索...',
        onChanged: (_) => _onSearchChanged(),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<_SearchResultDocument>>(
        stream: bookingStream,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            _lastBookingDocs = snapshot.data!;
          }
          final searchDocs = snapshot.data ?? _lastBookingDocs;
          if (snapshot.hasError && searchDocs.isEmpty) {
            return ErrorRetryView(onRetry: () => setState(() {}));
          }
          if (searchDocs.isEmpty && !snapshot.hasData) {
            return const LoadingView();
          }
          final query = searchQuery;
          final shouldFilterBySearch = query.isNotEmpty;
          final matchesQuery = _createFuzzyMatcher(
            query,
            enableSubsequence: false,
            enableEditDistance: false,
          );
          final searchedDocs =
              searchDocs.where((doc) {
                final data = doc.data;
                if (!shouldFilterBySearch) return true;
                final searchable = _buildBookingSearchSourceFromData(data);
                return matchesQuery(searchable);
              }).toList()..sort((a, b) {
                final aDate = (a.data['bookingDate'] ?? '').toString();
                final bDate = (b.data['bookingDate'] ?? '').toString();
                return bDate.compareTo(aDate);
              });

          final futureThreshold = DateTime(
            now.year,
            now.month,
            now.day,
          ).add(const Duration(days: 3));
          final visibleDocs = shouldFilterBySearch
              ? searchedDocs
              : searchedDocs.where((doc) {
                  final date = _tryParseDateFromText(
                    (doc.data['bookingDate'] ?? '').toString(),
                  );
                  if (date == null) return true;
                  return date.isBefore(futureThreshold);
                }).toList();
          final futureDocs = shouldFilterBySearch
              ? const <_SearchResultDocument>[]
              : searchedDocs.where((doc) {
                  final date = _tryParseDateFromText(
                    (doc.data['bookingDate'] ?? '').toString(),
                  );
                  if (date == null) return true;
                  return !date.isBefore(futureThreshold);
                }).toList();
          final dateFilteredDocs = shouldFilterBySearch
              ? visibleDocs
              : _showHiddenReservations
              ? futureDocs
              : visibleDocs;

          final monthKeys =
              dateFilteredDocs
                  .map((doc) {
                    final data = doc.data;
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
              ? dateFilteredDocs
              : dateFilteredDocs.where((doc) {
                  final data = doc.data;
                  final month = _extractMonthKey(
                    data['bookingDate']?.toString(),
                  );
                  return month == selectedMonth;
                }).toList();
          final hasMoreFetchedOlderDocs = false;
          final mayHaveMoreFromServer =
              !isSearching && searchDocs.length >= _bookingFetchLimit;
          final canLoadMore =
              !isSearching &&
              (hasMoreFetchedOlderDocs || mayHaveMoreFromServer);

          return Column(
            children: [
              if (snapshot.hasError)
                ErrorBanner(onRetry: () => setState(() {})),
              // 検索中はこのトグルが結果に一切影響しないため、押せそうに
              // 見えて実は無効というUIを避けるために非表示にする。
              if (!isSearching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Align(
                    alignment: Alignment.center,
                    child: ToggleFilterButton(
                      isActive: _showHiddenReservations,
                      icon: Icons.event_note_outlined,
                      activeIcon: Icons.visibility_off_rounded,
                      label: '先の予約',
                      activeLabel: '先の予約を隠す',
                      onPressed: () {
                        final nextValue = !_showHiddenReservations;
                        _invalidateSearchQueryCache(namespace: 'bookings');
                        setState(() {
                          _showHiddenReservations = nextValue;
                          if (nextValue) {
                            _selectedMonthKey = null;
                          }
                        });
                      },
                    ),
                  ),
                ),
              SizedBox(
                height: 45,
                child: ListView(
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
                ),
              ),
              Expanded(
                child: docs.isEmpty
                    ? RefreshIndicator(
                        onRefresh: _refreshBookings,
                        triggerMode: RefreshIndicatorTriggerMode.anywhere,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 80),
                            EmptyStateView(
                              icon: Icons.event_busy_outlined,
                              message: '該当する予約がありません',
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                  onRefresh: _refreshBookings,
                  triggerMode: RefreshIndicatorTriggerMode.anywhere,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount: docs.length + (canLoadMore ? 1 : 0),
                    separatorBuilder: (_, index) {
                      if (index >= docs.length - 1) {
                        return const SizedBox(height: 0);
                      }
                      return const SizedBox(height: 12);
                    },
                    itemBuilder: (context, index) {
                      if (index >= docs.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Center(
                            child: OutlinedButton.icon(
                              onPressed: _loadMoreBookings,
                              icon: const Icon(Icons.expand_more),
                              label: const Text('さらに表示'),
                            ),
                          ),
                        );
                      }
                      final booking = docs[index];
                      final data = booking.data;
                      final isCompactMobile =
                          MediaQuery.of(context).size.width < 430;
                      final bookingTags = _extractBookingTagsFromData(data);
                      final fallbackRetrospectiveChecked =
                          _isRetrospectiveChecked(data);
                      final isRetrospectiveChecked =
                          _retrospectiveCheckedOverrides[booking.id] ??
                          fallbackRetrospectiveChecked;
                      final List urls = data['imageUrls'] ?? [];

                      return SectionCard(
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          leading: urls.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    urls[0],
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    cacheWidth: 96,
                                    cacheHeight: 96,
                                    filterQuality: FilterQuality.medium,
                                  ),
                                )
                              : Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: AppColors.subtleFill,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(
                                    Icons.image_outlined,
                                    color: Colors.grey,
                                    size: 18,
                                  ),
                                ),
                          title: Text(
                            data['customerName'] ?? '',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            "${data['bookingDate']} / ${data['venueName']}",
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: SizedBox(
                            width: bookingTags.isNotEmpty
                                ? (isCompactMobile ? 200 : 216)
                                : (isCompactMobile ? 118 : 136),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                const Text(
                                  '振',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black54,
                                  ),
                                ),
                                const SizedBox(width: 1),
                                SizedBox(
                                  width: 24,
                                  child: Checkbox(
                                    value: isRetrospectiveChecked,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (value) {
                                      if (value == null) return;
                                      _setRetrospectiveChecked(
                                        bookingId: booking.id,
                                        nextValue: value,
                                        previousValue: isRetrospectiveChecked,
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 2),
                                if (bookingTags.isNotEmpty) ...[
                                  ...bookingTags.map(_buildBookingTagChip),
                                  const SizedBox(width: 4),
                                ],
                                _buildBookingLocationButton(data),
                                _buildBookingEstimateButton(data),
                              ],
                            ),
                          ),
                          onTap: () => showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: AppColors.surface,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20),
                              ),
                            ),
                            builder: (_) => BookingDetailSheet(
                              data: data,
                              docId: booking.id,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddBookingScreen()),
        ),
        backgroundColor: AppColors.brandOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.post_add),
        label: const Text('予約を登録'),
      ),
    );
  }
}
