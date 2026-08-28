part of '../main.dart';

// --- 会場マップビュー ---
class CsvBookingListScreen extends StatefulWidget {
  const CsvBookingListScreen({super.key});

  @override
  State<CsvBookingListScreen> createState() => _CsvBookingListScreenState();
}

class _CsvBookingListScreenState extends State<CsvBookingListScreen>
    with AutomaticKeepAliveClientMixin {
  late Future<List<_CsvBookingRow>> _rowsFuture;
  bool _showHiddenReservations = false;
  String? _selectedFilter;

  static const List<String> _filterLabels = ['OSAKA店頭', 'ZAIKI倉庫店頭', 'トラ・オペ'];

  String _normalizeFilterText(String value) {
    return value
        .toLowerCase()
        .replaceAll('ぺ', 'ペ')
        .replaceAll('ぺ'.toUpperCase(), 'ペ')
        .replaceAll('・', '')
        .replaceAll(' ', '');
  }

  bool _rowMatchesFilter(String keyword, _CsvBookingRow row) {
    final combined = _normalizeFilterText(
      '${row.fourthColumn} ${row.fifthColumn}',
    );
    return combined.contains(_normalizeFilterText(keyword));
  }

  String _normalizeToMmdd(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';

    final compactMatch = RegExp(
      r'^(\d{2})(\d{2})(?:\D.*)?$',
    ).firstMatch(trimmed);
    if (compactMatch != null) {
      final month = int.tryParse(compactMatch.group(1)!);
      final day = int.tryParse(compactMatch.group(2)!);
      if (month != null &&
          day != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= 31) {
        return '${month.toString().padLeft(2, '0')}${day.toString().padLeft(2, '0')}';
      }
    }

    final slashMatch = RegExp(
      r'^(\d{1,2})[/-](\d{1,2})(?:\D.*)?$',
    ).firstMatch(trimmed);
    if (slashMatch != null) {
      final month = int.tryParse(slashMatch.group(1)!);
      final day = int.tryParse(slashMatch.group(2)!);
      if (month != null &&
          day != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= 31) {
        return '${month.toString().padLeft(2, '0')}${day.toString().padLeft(2, '0')}';
      }
    }

    return '';
  }

  DateTime? _rowDate(_CsvBookingRow row) {
    final leftMmdd = _normalizeToMmdd(row.fourthColumn);
    final rightMmdd = _normalizeToMmdd(row.fifthColumn);
    final mmdd = leftMmdd.isNotEmpty ? leftMmdd : rightMmdd;
    if (mmdd.isEmpty) return null;
    final month = int.parse(mmdd.substring(0, 2));
    final day = int.parse(mmdd.substring(2, 4));
    final now = DateTime.now();
    var date = DateTime(now.year, month, day);
    // 半年以上先になる場合は前年とみなす
    if (date.difference(now).inDays > 180) {
      date = DateTime(now.year - 1, month, day);
    }
    return date;
  }

  String _buildDateGroupKey(DateTime? date) {
    if (date == null) return 'unknown';
    return DateFormat('yyyyMMdd').format(date);
  }

  String _formatDateGroupLabel(DateTime? date) {
    if (date == null) return '日付不明';
    return DateFormat('yyyy/MM/dd').format(date);
  }

  @override
  void initState() {
    super.initState();
    _rowsFuture = _fetchCsvBookingRows();
  }

  Future<void> _reload() async {
    setState(() {
      _rowsFuture = _fetchCsvBookingRows();
    });
    await _rowsFuture;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(title: const Text('見積一覧')),
      body: SelectionArea(
        child: FutureBuilder<List<_CsvBookingRow>>(
          future: _rowsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
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

            final allRows = snapshot.data ?? const <_CsvBookingRow>[];
            final now = DateTime.now();
            final threshold = DateTime(
              now.year,
              now.month,
              now.day,
            ).subtract(const Duration(days: 2));
            final rows = _showHiddenReservations
                ? allRows
                : allRows.where((row) {
                    final date = _rowDate(row);
                    if (date == null) return true;
                    return !date.isBefore(threshold);
                  }).toList();
            final filteredRows = _selectedFilter == null
                ? rows
                : rows
                      .where((r) => _rowMatchesFilter(_selectedFilter!, r))
                      .toList();

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Align(
                    alignment: Alignment.center,
                    child: OutlinedButton.icon(
                      onPressed: () => setState(
                        () =>
                            _showHiddenReservations = !_showHiddenReservations,
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: _showHiddenReservations
                              ? const Color.fromARGB(255, 255, 102, 0)
                              : const Color(0xFFDDDDDD),
                        ),
                        foregroundColor: _showHiddenReservations
                            ? const Color.fromARGB(255, 255, 102, 0)
                            : Colors.black54,
                        backgroundColor: _showHiddenReservations
                            ? const Color(0xFFFFF3E0)
                            : null,
                      ),
                      icon: Icon(
                        _showHiddenReservations
                            ? Icons.visibility_off_rounded
                            : Icons.event_note_outlined,
                      ),
                      label: Text(_showHiddenReservations ? '先の予約を隠す' : '先の予約'),
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: Center(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: _filterLabels.map((label) {
                          final selected = _selectedFilter == label;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(label),
                              selected: selected,
                              onSelected: (_) => setState(() {
                                _selectedFilter = selected ? null : label;
                              }),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: filteredRows.isEmpty
                      ? const Center(child: Text('表示できる予約データがありません'))
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            itemCount: (() {
                              final dateByKey = <String, DateTime?>{};
                              final grouped = <String, List<_CsvBookingRow>>{};
                              for (final row in filteredRows) {
                                final date = _rowDate(row);
                                final key = _buildDateGroupKey(date);
                                dateByKey.putIfAbsent(key, () => date);
                                grouped
                                    .putIfAbsent(key, () => <_CsvBookingRow>[])
                                    .add(row);
                              }
                              return grouped.length;
                            })(),
                            itemBuilder: (context, index) {
                              final dateByKey = <String, DateTime?>{};
                              final grouped = <String, List<_CsvBookingRow>>{};
                              for (final row in filteredRows) {
                                final date = _rowDate(row);
                                final key = _buildDateGroupKey(date);
                                dateByKey.putIfAbsent(key, () => date);
                                grouped
                                    .putIfAbsent(key, () => <_CsvBookingRow>[])
                                    .add(row);
                              }

                              final groupKeys =
                                  grouped.keys.toList(growable: false)
                                    ..sort((a, b) {
                                      final aDate = dateByKey[a];
                                      final bDate = dateByKey[b];
                                      if (aDate == null && bDate == null) {
                                        return 0;
                                      }
                                      if (aDate == null) return 1;
                                      if (bDate == null) return -1;
                                      return aDate.compareTo(bDate);
                                    });

                              final key = groupKeys[index];
                              final groupDate = dateByKey[key];
                              final rowsInDate =
                                  grouped[key] ?? const <_CsvBookingRow>[];
                              final isTodayGroup =
                                  groupDate != null &&
                                  DateFormat('yyyyMMdd').format(groupDate) ==
                                      DateFormat(
                                        'yyyyMMdd',
                                      ).format(DateTime.now());
                              final isTomorrowGroup =
                                  groupDate != null &&
                                  DateFormat('yyyyMMdd').format(groupDate) ==
                                      DateFormat('yyyyMMdd').format(
                                        DateTime.now().add(
                                          const Duration(days: 1),
                                        ),
                                      );

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                decoration: BoxDecoration(
                                  color: isTodayGroup
                                      ? const Color(0xFFE3F2FD)
                                      : isTomorrowGroup
                                      ? const Color(0xFFFFF59D)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isTodayGroup
                                        ? const Color(0xFF64B5F6)
                                        : isTomorrowGroup
                                        ? const Color(0xFFFFE082)
                                        : const Color(0xFFEEEEEE),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isTodayGroup
                                            ? const Color(0xFFBBDEFB)
                                            : isTomorrowGroup
                                            ? const Color(0xFFFFF176)
                                            : const Color(0xFFF8F8F8),
                                        borderRadius: const BorderRadius.only(
                                          topLeft: Radius.circular(12),
                                          topRight: Radius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        _formatDateGroupLabel(groupDate),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    ...rowsInDate.asMap().entries.map((entry) {
                                      final row = entry.value;
                                      final leftText = row.fourthColumn.trim();
                                      final rightText = row.fifthColumn.trim();
                                      final hasBoth =
                                          leftText.isNotEmpty &&
                                          rightText.isNotEmpty;
                                      final rowLabel = [
                                        leftText,
                                        rightText,
                                      ].where((e) => e.isNotEmpty).join(' ');
                                      final hasLineBreak =
                                          rowLabel.contains('\n') ||
                                          rowLabel.contains('\r');
                                      final isCanceledRow =
                                          !hasLineBreak &&
                                          rowLabel.contains('キャン');
                                      final rowTextStyle = TextStyle(
                                        fontWeight: FontWeight.w700,
                                        decoration: isCanceledRow
                                            ? TextDecoration.lineThrough
                                            : TextDecoration.none,
                                      );

                                      return Column(
                                        children: [
                                          if (entry.key > 0)
                                            Divider(
                                              height: 1,
                                              thickness: 1,
                                              color: isTodayGroup
                                                  ? const Color(0xFFBBDEFB)
                                                  : isTomorrowGroup
                                                  ? const Color(0xFFFFE082)
                                                  : const Color(0xFFF0F0F0),
                                            ),
                                          ListTile(
                                            dense: true,
                                            title: hasBoth
                                                ? Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Expanded(
                                                        child:
                                                            _buildPreservedCardText(
                                                              leftText,
                                                              style:
                                                                  rowTextStyle,
                                                              emptyPlaceholder:
                                                                  '(空行)',
                                                            ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child:
                                                            _buildPreservedCardText(
                                                              rightText,
                                                              style:
                                                                  rowTextStyle,
                                                              emptyPlaceholder:
                                                                  '(空行)',
                                                            ),
                                                      ),
                                                    ],
                                                  )
                                                : _buildPreservedCardText(
                                                    rowLabel,
                                                    style: rowTextStyle,
                                                    emptyPlaceholder: '(空行)',
                                                  ),
                                          ),
                                        ],
                                      );
                                    }),
                                  ],
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
      ),
    );
  }
}
