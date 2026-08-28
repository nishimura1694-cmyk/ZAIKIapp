part of '../main.dart';

// --- 会場一覧 ---
class VenueListScreen extends StatefulWidget {
  const VenueListScreen({super.key});
  @override
  State<VenueListScreen> createState() => _VenueListScreenState();
}

class _VenueListScreenState extends State<VenueListScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";
  String _selectedBlock = "すべて";
  int _venueFetchLimit = 9999;
  List<_SearchResultDocument> _lastVenueDocs = const [];
  _VenueAreaData? _areaData;

  @override
  void initState() {
    super.initState();
    _loadAreaData();
  }

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

  void _loadMoreVenues() {
    setState(() => _venueFetchLimit += _venuePageSize);
  }

  Future<void> _loadAreaData() async {
    try {
      final areaData = await _fetchVenueAreaData();
      if (!mounted) return;
      setState(() => _areaData = areaData);
    } catch (_) {
      // 読み込み失敗時は詳細表示時に再取得を試みる
    }
  }

  Future<_VenueAreaData?> _ensureAreaDataLoaded() async {
    final cached = _areaData;
    if (cached != null) return cached;

    try {
      final areaData = await _fetchVenueAreaData();
      if (!mounted) return areaData;
      setState(() => _areaData = areaData);
      return areaData;
    } catch (e) {
      if (mounted) {
        _showSnackBar('エリアデータの取得に失敗しました: $e');
      }
      return null;
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showAreaDialog(String selectedArea) async {
    final cachedAreaData = await _ensureAreaDataLoaded();
    if (cachedAreaData == null) {
      return;
    }

    final prefectures = cachedAreaData.areaTables[selectedArea] ?? const {};
    if (prefectures.isEmpty) {
      _showSnackBar('このエリアのデータがありません');
      return;
    }

    final prefectureEntries = prefectures.entries.toList(growable: false);
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: Text('$selectedAreaの詳細'),
        content: SizedBox(
          width: 400,
          child: ListView.separated(
            itemCount: prefectureEntries.length,
            separatorBuilder: (_, _) => const Divider(height: 24),
            itemBuilder: (context, index) {
              final entry = prefectureEntries[index];
              final prefecture = entry.key;
              final cities = entry.value;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prefecture,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.brandOrangeDark,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: cities
                        .map(
                          (city) => Chip(
                            label: Text(
                              city,
                              style: const TextStyle(fontSize: 12),
                            ),
                            backgroundColor: AppColors.subtleFill,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshVenues() async {
    clearSearch();
    _invalidateSearchQueryCache(namespace: 'venues');
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
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final searchQuery = _searchQuery.trim();
    final isSearching = searchQuery.isNotEmpty;
    final venueStream = _buildIndexedSearchStream(
      cacheNamespace: 'venues',
      collection: FirebaseFirestore.instance.collection('venues'),
      searchQuery: searchQuery,
      idleLimit: _venueFetchLimit,
      searchLimit: _venueSearchCandidateLimit,
      fallbackQueryBuilder: (collection, limit) =>
          collection.orderBy('name').limit(limit),
    );

    return Scaffold(
      appBar: SearchAppBar(
        title: '会場一覧',
        controller: _searchController,
        hintText: '会場名・部屋名で検索...',
        onChanged: (_) => _onSearchChanged(),
        filterRow: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: <String>['すべて', ..._venueAreaSectionOrder]
              .map(
                (block) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChoiceChip(
                        label: Text(block),
                        selected: _selectedBlock == block,
                        onSelected: (selected) =>
                            setState(() => _selectedBlock = block),
                        selectedColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                      ),
                      if (block != 'すべて')
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => _showAreaDialog(block),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.info_outline,
                                size: 18,
                                color: AppColors.brandOrange,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ),
      body: StreamBuilder<List<_SearchResultDocument>>(
        stream: venueStream,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            _lastVenueDocs = snapshot.data!;
          }
          final searchDocs = snapshot.data ?? _lastVenueDocs;
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
          final docs =
              searchDocs.where((doc) {
                final data = doc.data;
                final searchable = _buildVenueSearchSourceFromData(data);
                final isMatched =
                    !shouldFilterBySearch || matchesQuery(searchable);
                return isMatched &&
                    (_selectedBlock == "すべて" ||
                        data['block'] == _selectedBlock);
              }).toList()..sort((a, b) {
                final aName = (a.data['name'] ?? '').toString();
                final bName = (b.data['name'] ?? '').toString();
                return aName.compareTo(bName);
              });
          final canLoadMore =
              !isSearching && searchDocs.length >= _venueFetchLimit;
          if (docs.isEmpty) {
            return Column(
              children: [
                if (snapshot.hasError)
                  ErrorBanner(onRetry: () => setState(() {})),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshVenues,
                    triggerMode: RefreshIndicatorTriggerMode.anywhere,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 80),
                        EmptyStateView(
                          icon: Icons.location_city_outlined,
                          message: '該当する会場がありません',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              if (snapshot.hasError)
                ErrorBanner(onRetry: () => setState(() {})),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refreshVenues,
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
                              onPressed: _loadMoreVenues,
                              icon: const Icon(Icons.expand_more),
                              label: const Text('さらに表示'),
                            ),
                          ),
                        );
                      }
                      final data = docs[index].data;
                      final hasAddress = (data['address'] ?? '')
                          .toString()
                          .isNotEmpty;
                      final hasAttention = _extractVenueAttentionItems(
                        data,
                      ).isNotEmpty;
                      final hasExtraCharge = _extractVenueExtraChargeNote(
                        data,
                      ).isNotEmpty;
                      return SectionCard(
                        child: ListTile(
                          title: Row(
                            children: [
                              if (hasAttention) ...[
                                const Tooltip(
                                  message: '要注意項目あり',
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    color: AppColors.danger,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              if (hasExtraCharge) ...[
                                const Tooltip(
                                  message: '追加料金発生あり',
                                  child: Icon(
                                    Icons.currency_yen_rounded,
                                    color: Colors.deepOrange,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  data['name'] ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            "エリア: ${data['block'] ?? '-'} / ${data['shopAndRoom'] ?? '-'}",
                          ),
                          trailing: SizedBox(
                            width: 88,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                hasAddress
                                    ? IconButton(
                                        icon: const Icon(Icons.location_on),
                                        color: AppColors.brandOrange,
                                        tooltip: '地図アプリで開く',
                                        onPressed: () async {
                                          final address = data['address'] ?? '';
                                          final String uri =
                                              'https://maps.google.com/?q=${Uri.encodeComponent(address)}';
                                          try {
                                            if (await canLaunchUrl(
                                              Uri.parse(uri),
                                            )) {
                                              await launchUrl(
                                                Uri.parse(uri),
                                                mode: LaunchMode
                                                    .externalApplication,
                                              );
                                            } else {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      '地図アプリを開けませんでした',
                                                    ),
                                                  ),
                                                );
                                              }
                                            }
                                          } catch (e) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text('エラー: $e'),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                      )
                                    : SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: Center(
                                          child: Icon(
                                            Icons.location_on,
                                            color: Colors.grey[400],
                                            size: 22,
                                          ),
                                        ),
                                      ),
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
                            builder: (_) => VenueDetailSheet(
                              data: data,
                              docId: docs[index].id,
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
          MaterialPageRoute(builder: (_) => const AddVenueScreen()),
        ),
        backgroundColor: AppColors.brandOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('会場を追加'),
      ),
    );
  }
}
