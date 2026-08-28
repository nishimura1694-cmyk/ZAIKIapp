part of '../main.dart';

class TodayRowsFromSourceCsvScreen extends StatefulWidget {
  const TodayRowsFromSourceCsvScreen({super.key});

  @override
  State<TodayRowsFromSourceCsvScreen> createState() =>
      _TodayRowsFromSourceCsvScreenState();
}

class _TodayRowsFromSourceCsvScreenState
    extends State<TodayRowsFromSourceCsvScreen>
    with AutomaticKeepAliveClientMixin {
  late Future<List<_WeeklySourceDayData>> _todayRowsFuture;
  String? _selectedSourceFilter;

  static const List<String> _sourceFilters = ['【ZAIKI】', '【OSAKA】'];

  @override
  void initState() {
    super.initState();
    _todayRowsFuture = _fetchWeeklyRowsFromSourceCsv();
  }

  Future<void> _reload() async {
    setState(() {
      _todayRowsFuture = _fetchWeeklyRowsFromSourceCsv();
    });
    await _todayRowsFuture;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZAIKI表データ'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('すべて'),
                  selected: _selectedSourceFilter == null,
                  onSelected: (_) {
                    setState(() => _selectedSourceFilter = null);
                  },
                ),
                ..._sourceFilters.map(
                  (filter) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(filter),
                      selected: _selectedSourceFilter == filter,
                      onSelected: (_) {
                        setState(() {
                          _selectedSourceFilter =
                              _selectedSourceFilter == filter ? null : filter;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SelectionArea(
        child: FutureBuilder<List<_WeeklySourceDayData>>(
          future: _todayRowsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LoadingView();
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      Text(
                        'CSVの読み込みに失敗しました\n${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
                      ),
                    ],
                  ),
                ),
              );
            }

            final weekRows = snapshot.data ?? const <_WeeklySourceDayData>[];
            if (weekRows.isEmpty) {
              return RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 220),
                    EmptyStateView(message: '1か月分の抽出データは見つかりませんでした'),
                  ],
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: weekRows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final day = weekRows[index];
                  final groupedValues =
                      <
                        String,
                        List<({int columnIndex, String thirdRowValue})>
                      >{};
                  final groupedSeenKeys = <String, Set<String>>{};
                  final groupedDisplayValueByKey = <String, String>{};

                  for (final column in day.columns) {
                    for (final value in column.todayValues) {
                      if (_shouldIgnoreTodayExtractedValue(value)) continue;
                      final groupingKey = _normalizeTodayPersonGroupingKey(
                        value,
                      );
                      final normalizedThirdRowValue = _normalizeThirdRowValue(
                        column.thirdRowValue,
                      );
                      final entries = groupedValues.putIfAbsent(
                        groupingKey,
                        () => <({int columnIndex, String thirdRowValue})>[],
                      );
                      groupedDisplayValueByKey.putIfAbsent(
                        groupingKey,
                        () => value,
                      );
                      final seenKeys = groupedSeenKeys.putIfAbsent(
                        groupingKey,
                        () => <String>{},
                      );
                      final dedupKey =
                          '${column.columnIndex}::${normalizedThirdRowValue.trim()}';
                      if (seenKeys.add(dedupKey)) {
                        entries.add((
                          columnIndex: column.columnIndex,
                          thirdRowValue: normalizedThirdRowValue,
                        ));
                      }
                    }
                  }

                  final groupedEntries = groupedValues.entries.toList(
                    growable: false,
                  );
                  int sourceOrder(String name) {
                    if (name.contains('【ZAIKI】')) return 0;
                    if (name.contains('【OSAKA】')) return 1;
                    return 2;
                  }

                  groupedEntries.sort((a, b) {
                    final aLabel = groupedDisplayValueByKey[a.key] ?? a.key;
                    final bLabel = groupedDisplayValueByKey[b.key] ?? b.key;
                    final sourceCompare = sourceOrder(
                      aLabel,
                    ).compareTo(sourceOrder(bLabel));
                    if (sourceCompare != 0) return sourceCompare;
                    return aLabel.compareTo(bLabel);
                  });
                  final visibleGroupedEntries = groupedEntries
                      .where((entry) {
                        if (_selectedSourceFilter == null) return true;
                        final label =
                            groupedDisplayValueByKey[entry.key] ?? entry.key;
                        return label.contains(_selectedSourceFilter!);
                      })
                      .toList(growable: false);
                  final dateLabel = DateFormat('M/d(E)', 'ja').format(day.date);
                  final dayKey = DateFormat('yyyyMMdd').format(day.date);
                  final todayKey = DateFormat(
                    'yyyyMMdd',
                  ).format(DateTime.now());
                  final tomorrowKey = DateFormat(
                    'yyyyMMdd',
                  ).format(DateTime.now().add(const Duration(days: 1)));
                  final isTodayGroup = dayKey == todayKey;
                  final isTomorrowGroup = dayKey == tomorrowKey;

                  final dayPalette = StatusPalette.forDateGroup(
                    isToday: isTodayGroup,
                    isTomorrow: isTomorrowGroup,
                  );
                  final dayHeaderColor = isTodayGroup
                      ? const Color(0xFFBBDEFB)
                      : isTomorrowGroup
                      ? const Color(0xFFFFF176)
                      : const Color(0xFFF8F8F8);
                  return Container(
                    decoration: BoxDecoration(
                      color: dayPalette.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: dayPalette.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: dayHeaderColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Text(
                                dateLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (visibleGroupedEntries.isEmpty)
                            Text(
                              '抽出データなし',
                              style: TextStyle(color: Colors.grey[600]),
                            )
                          else
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: visibleGroupedEntries
                                    .map((item) {
                                      final thirdRowGroups =
                                          <String, List<int>>{};
                                      for (final entry in item.value) {
                                        thirdRowGroups
                                            .putIfAbsent(
                                              entry.thirdRowValue,
                                              () => <int>[],
                                            )
                                            .add(entry.columnIndex);
                                      }

                                      return Container(
                                        width: 240,
                                        margin: const EdgeInsets.only(
                                          right: 10,
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: AppColors.dividerGrey,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Text(
                                                groupedDisplayValueByKey[item
                                                        .key] ??
                                                    item.key,
                                                softWrap: false,
                                                maxLines: 1,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            ...thirdRowGroups.entries.map((
                                              entry,
                                            ) {
                                              final thirdRowValue = entry.key;
                                              final columnIndexes = entry.value
                                                ..sort(
                                                  (a, b) => a.compareTo(b),
                                                );
                                              final count =
                                                  columnIndexes.length;
                                              final countSuffix = count > 1
                                                  ? ' *$count'
                                                  : '';
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 6,
                                                ),
                                                child: Text(
                                                  thirdRowValue.isEmpty
                                                      ? '(空欄)$countSuffix'
                                                      : '$thirdRowValue$countSuffix',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              );
                                            }),
                                          ],
                                        ),
                                      );
                                    })
                                    .toList(growable: false),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
