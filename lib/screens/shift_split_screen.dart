part of '../main.dart';

// --- シフト + ZAIKI表データ 縦分割画面 ---
class ShiftSplitScreen extends StatefulWidget {
  const ShiftSplitScreen({super.key});

  @override
  State<ShiftSplitScreen> createState() => _ShiftSplitScreenState();
}

class _ShiftSplitScreenState extends State<ShiftSplitScreen>
    with AutomaticKeepAliveClientMixin {
  late Future<(List<_ExtractedDateRow>, List<_WeeklySourceDayData>)>
  _combinedFuture;
  String? _selectedSourceFilter;
  static const List<String> _sourceFilters = ['【ZAIKI】', '【OSAKA】'];
  bool _showZaikiPanel = false;

  final List<ScrollController> _rowControllers = [];
  bool _syncingScroll = false;

  static const double _shiftColumnWidth = 300;
  static const double _compactShiftColumnWidth = 150;
  static const Set<String> _numericSortColumnKeys = {
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
  };

  @override
  void initState() {
    super.initState();
    _combinedFuture = _loadBoth();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in _rowControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<(List<_ExtractedDateRow>, List<_WeeklySourceDayData>)>
  _loadBoth() async {
    final results = await Future.wait([
      _fetchDateRowsFromCsv(),
      _fetchWeeklyRowsFromSourceCsv(),
    ]);
    return (
      results[0] as List<_ExtractedDateRow>,
      results[1] as List<_WeeklySourceDayData>,
    );
  }

  Future<void> _reload() async {
    setState(() {
      _combinedFuture = _loadBoth();
    });
    await _combinedFuture;
  }

  ScrollController _getOrCreateRowController(int index) {
    while (_rowControllers.length <= index) {
      final controller = ScrollController();
      final idx = _rowControllers.length;
      controller.addListener(() {
        if (_syncingScroll) return;
        if (!controller.hasClients) return;
        _syncingScroll = true;
        final offset = controller.offset;
        for (var i = 0; i < _rowControllers.length; i++) {
          if (i == idx) continue;
          final other = _rowControllers[i];
          if (other.hasClients &&
              other.position.maxScrollExtent > 0 &&
              other.offset != offset) {
            other.jumpTo(offset.clamp(0.0, other.position.maxScrollExtent));
          }
        }
        _syncingScroll = false;
      });
      _rowControllers.add(controller);
    }
    return _rowControllers[index];
  }

  // ---- shift helpers (pure, copied from _DateExtractListScreenState) ----

  List<_DateColumnSection> _buildColumnSections(_ExtractedDateRow row) {
    final sections = <_DateColumnSection>[];
    const bookingColumnKey = '__BOOKING__';
    final bookingLabel = row.mToTLabelsByKey[bookingColumnKey] ?? '見積一覧';
    final bookingValues = List<String>.from(
      row.mToTValuesByKey[bookingColumnKey] ?? const <String>[],
    );
    sections.add(
      _DateColumnSection(
        label: bookingLabel,
        values: bookingValues,
        isBookingCard: true,
      ),
    );
    sections.add(
      _DateColumnSection(label: row.kColumnLabel, values: row.kValues),
    );
    for (final key in row.mToTColumnOrder) {
      if (key == bookingColumnKey) continue;
      final label = row.mToTLabelsByKey[key] ?? '$key列';
      final rawValues = row.mToTValuesByKey[key] ?? const <String>[];
      final values = List<String>.from(rawValues);
      if (_numericSortColumnKeys.contains(key)) {
        values.sort(_compareNumericText);
      }
      sections.add(_DateColumnSection(label: label, values: values));
    }
    return sections;
  }

  String _normalizeBookingMatchText(String value) {
    return value
        .toLowerCase()
        .replaceAll('ぺ', 'ペ')
        .replaceAll('・', '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  bool _bookingValueMatchesFilter(String keyword, String value) =>
      _normalizeBookingMatchText(
        value,
      ).contains(_normalizeBookingMatchText(keyword));

  bool _sectionLabelMatchesTarget(String sectionLabel, String targetLabel) =>
      _normalizeBookingMatchText(
        sectionLabel,
      ).contains(_normalizeBookingMatchText(targetLabel));

  String _buildBookingSectionLabel(String bookingLabel, String filterLabel) {
    final nb = bookingLabel.trim();
    final nf = filterLabel.trim();
    if (nf.isEmpty) return nb;
    if (nb.contains(nf)) return nb;
    return '$nf$nb';
  }

  Map<String, _DateColumnSection> _buildBookingSectionsByTarget(
    _DateColumnSection? bookingSection,
  ) {
    if (bookingSection == null) return const {};
    const bookingTargetByFilter = <String, String>{
      'トラ・オペ': 'トラポ予約',
      'ZAIKI倉庫店頭': '店頭予約・業務',
      'OSAKA店頭': 'TODO',
    };
    final sections = <String, _DateColumnSection>{};
    for (final entry in bookingTargetByFilter.entries) {
      final matchedValues = bookingSection.values
          .where((v) => _bookingValueMatchesFilter(entry.key, v))
          .toList(growable: false);
      if (matchedValues.isEmpty) continue;
      sections[entry.value] = _DateColumnSection(
        label: _buildBookingSectionLabel(bookingSection.label, entry.key),
        values: matchedValues,
        isBookingCard: true,
      );
    }
    return sections;
  }

  _DateColumnSection? _findAttachedBookingSection(
    String sectionLabel,
    Map<String, _DateColumnSection> bookingSectionsByTarget,
  ) {
    for (final entry in bookingSectionsByTarget.entries) {
      if (_sectionLabelMatchesTarget(sectionLabel, entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  String? _bookingFilterLabelForSection(String sectionLabel) {
    const filterLabelByTarget = <String, String>{
      'トラポ予約': 'トラ・オペ',
      '店頭予約・業務': 'ZAIKI倉庫店頭',
      'TODO': 'OSAKA店頭',
    };
    for (final entry in filterLabelByTarget.entries) {
      if (_sectionLabelMatchesTarget(sectionLabel, entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  _DateColumnSection _buildEmptyAttachedBookingSection(
    String sectionLabel,
    _DateColumnSection? bookingSection,
  ) {
    final bookingLabel = bookingSection?.label ?? '見積一覧';
    final filterLabel = _bookingFilterLabelForSection(sectionLabel);
    return _DateColumnSection(
      label: filterLabel == null
          ? bookingLabel
          : _buildBookingSectionLabel(bookingLabel, filterLabel),
      values: const <String>[],
      isBookingCard: true,
    );
  }

  _DateColumnSection? _buildRemainingBookingSection(
    _DateColumnSection? bookingSection,
    Map<String, _DateColumnSection> bookingSectionsByTarget,
  ) {
    if (bookingSection == null) return null;
    final attachedValues = bookingSectionsByTarget.values
        .expand((s) => s.values)
        .toSet();
    final remaining = bookingSection.values
        .where((v) => !attachedValues.contains(v))
        .toList(growable: false);
    if (remaining.isEmpty) return null;
    return _DateColumnSection(
      label: bookingSection.label,
      values: remaining,
      isBookingCard: true,
    );
  }

  static const List<String> _bookingTitleOnlyLabels = [
    'トラ・オペ',
    'OSAKA店頭',
    'ZAIKI倉庫店頭',
  ];

  String? _hiddenBookingLabelForSection(_DateColumnSection section) {
    if (!section.isBookingCard) return null;
    final normalized = _normalizeBookingMatchText(section.label);
    for (final label in _bookingTitleOnlyLabels) {
      if (normalized.contains(_normalizeBookingMatchText(label))) return label;
    }
    return null;
  }

  String _stripBookingLabelFromLine(String line, String label) {
    switch (label) {
      case 'トラ・オペ':
        return line.replaceAll(
          RegExp(r'\s*[／/]?\s*トラ\s*[・･]?\s*オペ\s*[／/]?\s*'),
          ' ',
        );
      case 'OSAKA店頭':
        return line.replaceAll(
          RegExp(r'\s*[／/]?\s*OSAKA\s*店頭\s*[／/]?\s*', caseSensitive: false),
          ' ',
        );
      case 'ZAIKI倉庫店頭':
        return line.replaceAll(
          RegExp(
            r'\s*[／/]?\s*ZAIKI\s*倉庫\s*店頭\s*[／/]?\s*',
            caseSensitive: false,
          ),
          ' ',
        );
      default:
        return line;
    }
  }

  String _sanitizeSectionValueForDisplay(
    _DateColumnSection section,
    String value,
  ) {
    var normalized = _normalizeCardMultilineText(value);
    final hiddenLabel = _hiddenBookingLabelForSection(section);
    if (hiddenLabel != null) {
      normalized = normalized
          .split('\n')
          .map(
            (line) => _stripBookingLabelFromLine(line, hiddenLabel)
                .replaceAll(RegExp(r'\s*[／/]\s*'), ' ')
                .replaceAll(RegExp(r'\s{2,}'), ' ')
                .trim(),
          )
          .join('\n');
    }
    return normalized;
  }

  double _columnWidthForSection(_DateColumnSection section) {
    final normalized = section.label.toLowerCase().replaceAll(
      RegExp(r'[\s　]+'),
      '',
    );
    const compactKeywords = <String>[
      'desk',
      'field',
      'build',
      'other',
      'help',
      '予定',
      '休み',
    ];
    return compactKeywords.any(normalized.contains)
        ? _compactShiftColumnWidth
        : _shiftColumnWidth;
  }

  double _measureTextHeight(
    BuildContext context,
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.trim().isEmpty ? ' ' : _normalizeCardMultilineText(text),
        style: style,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return painter.height;
  }

  double _estimateBookingCardHeight(
    BuildContext context,
    _DateColumnSection section,
  ) {
    const minHeight = 96.0;
    const horizontalPadding = 20.0;
    const verticalPadding = 20.0;
    const labelGap = 6.0;
    const itemSpacing = 4.0;
    const labelStyle = TextStyle(fontWeight: FontWeight.w700);
    final contentWidth = _shiftColumnWidth - horizontalPadding;
    final bodyStyle = DefaultTextStyle.of(context).style;
    var h =
        verticalPadding +
        _measureTextHeight(context, section.label, labelStyle, contentWidth) +
        labelGap;
    if (section.values.isEmpty) return h < minHeight ? minHeight : h;
    for (var i = 0; i < section.values.length; i++) {
      h += _measureTextHeight(
        context,
        _sanitizeSectionValueForDisplay(section, section.values[i]),
        bodyStyle,
        contentWidth,
      );
      if (i < section.values.length - 1) h += itemSpacing;
    }
    return h < minHeight ? minHeight : h;
  }

  double? _buildUniformBookingCardHeight(
    BuildContext context,
    _DateColumnSection? remainingBookingSection,
    Map<String, _DateColumnSection> bookingSectionsByTarget,
  ) {
    final bookingSections = <_DateColumnSection>[
      ...?remainingBookingSection == null ? null : [remainingBookingSection],
      ...bookingSectionsByTarget.values,
    ];
    if (bookingSections.isEmpty) {
      final emptyBookingSection = _DateColumnSection(
        label: '見積一覧',
        values: const <String>[],
        isBookingCard: true,
      );
      return _estimateBookingCardHeight(context, emptyBookingSection) + 8;
    }
    var maxH = 0.0;
    for (final s in bookingSections) {
      final h = _estimateBookingCardHeight(context, s);
      if (h > maxH) maxH = h;
    }
    return maxH + 8;
  }

  Widget _buildColumnCard(
    _DateColumnSection section, {
    Color? backgroundColor,
    Color? borderColor,
    double? fixedHeight,
  }) {
    final values = section.values;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: Text(
            section.label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 6),
        ...() {
          final children = <Widget>[];
          var canceledBookingBlock = false;
          final continuationPattern = RegExp(
            r'^\s*(?:[0-9０-９]+\s*[PＰpｐ]|搬入(?:予定)?|搬出(?:予定)?)',
          );
          for (final value in values) {
            final displayValue = _sanitizeSectionValueForDisplay(
              section,
              value,
            );
            final lines = displayValue.split(RegExp(r'\r?\n'));
            final spans = <InlineSpan>[];
            for (var li = 0; li < lines.length; li++) {
              final line = lines[li];
              final trimmed = line.trim();
              final hasCancel = line.contains('キャン');
              final isContinuation = continuationPattern.hasMatch(trimmed);
              if (section.isBookingCard) {
                if (trimmed.isEmpty) {
                  // keep block state
                } else if (hasCancel) {
                  canceledBookingBlock = true;
                } else if (!isContinuation) {
                  canceledBookingBlock = false;
                }
              }
              final isCanceled = section.isBookingCard
                  ? (hasCancel || (canceledBookingBlock && isContinuation))
                  : hasCancel;
              spans.add(
                TextSpan(
                  text: section.isBookingCard ? trimmed : line,
                  style: TextStyle(
                    decoration: isCanceled
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              );
              if (li < lines.length - 1) spans.add(const TextSpan(text: '\n'));
            }
            children.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: section.isBookingCard
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text.rich(
                          TextSpan(children: spans),
                          softWrap: false,
                        ),
                      )
                    : Text.rich(TextSpan(children: spans)),
              ),
            );
          }
          return children;
        }(),
      ],
    );
    return Container(
      constraints: fixedHeight == null
          ? null
          : BoxConstraints(minHeight: fixedHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: backgroundColor ?? const Color(0xFFFFFBF7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor ?? const Color(0xFFFFE0CC)),
      ),
      child: content,
    );
  }

  // ---- ZAIKI panel for a single day ----

  Widget _buildZaikiDayPanel(
    _WeeklySourceDayData? day,
    bool isToday,
    bool isTomorrow,
  ) {
    if (day == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.subtleFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.dividerGrey),
        ),
        child: Text(
          'データなし',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
      );
    }

    final groupedValues =
        <String, List<({int columnIndex, String thirdRowValue})>>{};
    final groupedSeenKeys = <String, Set<String>>{};
    final groupedDisplayValueByKey = <String, String>{};

    for (final column in day.columns) {
      for (final value in column.todayValues) {
        if (_shouldIgnoreTodayExtractedValue(value)) continue;
        final groupingKey = _normalizeTodayPersonGroupingKey(value);
        final normalizedThirdRowValue = _normalizeThirdRowValue(
          column.thirdRowValue,
        );
        final entries = groupedValues.putIfAbsent(
          groupingKey,
          () => <({int columnIndex, String thirdRowValue})>[],
        );
        groupedDisplayValueByKey.putIfAbsent(groupingKey, () => value);
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

    final groupedEntries = groupedValues.entries.toList(growable: false);
    int sourceOrder(String name) {
      if (name.contains('【ZAIKI】')) return 0;
      if (name.contains('【OSAKA】')) return 1;
      return 2;
    }

    groupedEntries.sort((a, b) {
      final aLabel = groupedDisplayValueByKey[a.key] ?? a.key;
      final bLabel = groupedDisplayValueByKey[b.key] ?? b.key;
      final sc = sourceOrder(aLabel).compareTo(sourceOrder(bLabel));
      if (sc != 0) return sc;
      return aLabel.compareTo(bLabel);
    });

    final visibleEntries = _selectedSourceFilter == null
        ? groupedEntries
        : groupedEntries
              .where((entry) {
                final label = groupedDisplayValueByKey[entry.key] ?? entry.key;
                return label.contains(_selectedSourceFilter!);
              })
              .toList(growable: false);

    if (visibleEntries.isEmpty) {
      return Text(
        '抽出データなし',
        style: TextStyle(color: Colors.grey[600], fontSize: 12),
      );
    }

    Widget buildCard(
      MapEntry<String, List<({int columnIndex, String thirdRowValue})>> item,
    ) {
      final thirdRowGroups = <String, List<int>>{};
      for (final entry in item.value) {
        thirdRowGroups
            .putIfAbsent(entry.thirdRowValue, () => <int>[])
            .add(entry.columnIndex);
      }
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.dividerGrey),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                groupedDisplayValueByKey[item.key] ?? item.key,
                softWrap: false,
                maxLines: 1,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 6),
            ...thirdRowGroups.entries.map((entry) {
              final count = entry.value.length;
              final countSuffix = count > 1 ? ' *$count' : '';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  entry.key.isEmpty
                      ? '(空欄)$countSuffix'
                      : '${entry.key}$countSuffix',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              );
            }),
          ],
        ),
      );
    }

    // 2列グリッド: 固定幅カード×2列、横スクロール対応
    const double cardWidth = 220.0;
    const double cardGap = 8.0;

    final rows = <Widget>[];
    for (var i = 0; i < visibleEntries.length; i += 2) {
      final left = visibleEntries[i];
      final right = i + 1 < visibleEntries.length
          ? visibleEntries[i + 1]
          : null;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: cardWidth, child: buildCard(left)),
                if (right != null) ...[
                  const SizedBox(width: cardGap),
                  SizedBox(width: cardWidth, child: buildCard(right)),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('シフト'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('ZAIKI/OSAKA機材を表示'),
                  selected: _showZaikiPanel,
                  onSelected: (value) =>
                      setState(() => _showZaikiPanel = value),
                ),
                if (_showZaikiPanel) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('すべて'),
                    selected: _selectedSourceFilter == null,
                    onSelected: (_) =>
                        setState(() => _selectedSourceFilter = null),
                  ),
                  ..._sourceFilters.map(
                    (filter) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(filter),
                        selected: _selectedSourceFilter == filter,
                        onSelected: (_) => setState(() {
                          _selectedSourceFilter =
                              _selectedSourceFilter == filter ? null : filter;
                        }),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      body: SelectionArea(
        child: FutureBuilder<(List<_ExtractedDateRow>, List<_WeeklySourceDayData>)>(
          future: _combinedFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SkeletonList();
            }
            if (snapshot.hasError) {
              return ErrorRetryView(
                message: 'データの読み込みに失敗しました',
                onRetry: _reload,
              );
            }

            final (shiftRows, zaikiRows) =
                snapshot.data ??
                (const <_ExtractedDateRow>[], const <_WeeklySourceDayData>[]);

            final now = DateTime.now();
            final threshold = DateTime(now.year, now.month, now.day);

            // Collect all upcoming dates from both sources
            final shiftByDate = <String, _ExtractedDateRow>{};
            for (final row in shiftRows) {
              if (!row.date.isBefore(threshold)) {
                final key = DateFormat('yyyyMMdd').format(row.date);
                shiftByDate[key] = row;
              }
            }
            final zaikiByDate = <String, _WeeklySourceDayData>{};
            for (final day in zaikiRows) {
              if (!day.date.isBefore(threshold)) {
                final key = DateFormat('yyyyMMdd').format(day.date);
                zaikiByDate[key] = day;
              }
            }

            // Union of all dates, sorted
            final allDateKeys = ({
              ...shiftByDate.keys,
              ...zaikiByDate.keys,
            }).toList()..sort();

            if (allDateKeys.isEmpty) {
              return RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 220),
                    EmptyStateView(message: '表示できるデータがありません'),
                  ],
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                itemCount: allDateKeys.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final dateKey = allDateKeys[index];
                  final shiftRow = shiftByDate[dateKey];
                  final zaikiDay = zaikiByDate[dateKey];

                  final date = shiftRow?.date ?? zaikiDay!.date;
                  final today = DateTime.now();
                  final tomorrow = today.add(const Duration(days: 1));
                  final isToday =
                      date.year == today.year &&
                      date.month == today.month &&
                      date.day == today.day;
                  final isTomorrow =
                      date.year == tomorrow.year &&
                      date.month == tomorrow.month &&
                      date.day == tomorrow.day;

                  final dateLabel = DateFormat('M月d日(E)', 'ja').format(date);

                  // Build shift panel
                  Widget shiftPanel;
                  if (shiftRow == null) {
                    shiftPanel = Text(
                      'シフトデータなし',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    );
                  } else {
                    final sections = _buildColumnSections(shiftRow);
                    final bookingSection = sections
                        .where((s) => s.isBookingCard)
                        .cast<_DateColumnSection?>()
                        .firstWhere((_) => true, orElse: () => null);
                    final bookingSectionsByTarget =
                        _buildBookingSectionsByTarget(bookingSection);
                    final remainingBookingSection =
                        _buildRemainingBookingSection(
                          bookingSection,
                          bookingSectionsByTarget,
                        );
                    final uniformBookingCardHeight =
                        _buildUniformBookingCardHeight(
                          context,
                          remainingBookingSection,
                          bookingSectionsByTarget,
                        );
                    final otherSections = sections
                        .where((s) => !s.isBookingCard)
                        .toList(growable: false);
                    final rowController = _getOrCreateRowController(index);

                    shiftPanel = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (remainingBookingSection != null) ...[
                          SizedBox(
                            width: double.infinity,
                            child: _buildColumnCard(
                              remainingBookingSection,
                              backgroundColor: StatusPalette.forDateGroup(
                                isToday: isToday,
                                isTomorrow: isTomorrow,
                                otherwise: StatusPalette.grey,
                              ).background,
                              borderColor: StatusPalette.forDateGroup(
                                isToday: isToday,
                                isTomorrow: isTomorrow,
                                otherwise: StatusPalette.grey,
                              ).border,
                              fixedHeight: uniformBookingCardHeight,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          controller: rowController,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (otherSections.any(
                                (s) =>
                                    _columnWidthForSection(s) ==
                                    _compactShiftColumnWidth,
                              ))
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: SizedBox(
                                    width: _compactShiftColumnWidth,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        // Date card above field
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: StatusPalette.forDateGroup(
                                              isToday: isToday,
                                              isTomorrow: isTomorrow,
                                              otherwise: StatusPalette.grey,
                                            ).background,
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: StatusPalette.forDateGroup(
                                                isToday: isToday,
                                                isTomorrow: isTomorrow,
                                                otherwise: StatusPalette.grey,
                                              ).border,
                                            ),
                                          ),
                                          constraints:
                                              uniformBookingCardHeight == null
                                              ? null
                                              : BoxConstraints(
                                                  minHeight:
                                                      uniformBookingCardHeight,
                                                ),
                                          child: Center(
                                            child: Text(
                                              dateLabel,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 16,
                                              ),
                                              textAlign: TextAlign.center,
                                              softWrap: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        ...(() {
                                          int compactOrder(
                                            _DateColumnSection s,
                                          ) {
                                            final n = s.label
                                                .toLowerCase()
                                                .replaceAll(
                                                  RegExp(r'[\s\u3000]+'),
                                                  '',
                                                );
                                            if (n.contains('field')) return 0;
                                            if (n.contains('desk')) return 1;
                                            return 2;
                                          }

                                          return (otherSections
                                              .where(
                                                (s) =>
                                                    _columnWidthForSection(s) ==
                                                    _compactShiftColumnWidth,
                                              )
                                              .toList()
                                            ..sort(
                                              (a, b) => compactOrder(
                                                a,
                                              ).compareTo(compactOrder(b)),
                                            ));
                                        })().map(
                                          (section) => Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 8,
                                            ),
                                            child: _buildColumnCard(section),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ...otherSections
                                  .where(
                                    (s) =>
                                        _columnWidthForSection(s) ==
                                        _shiftColumnWidth,
                                  )
                                  .map((section) {
                                    final attached =
                                        _findAttachedBookingSection(
                                          section.label,
                                          bookingSectionsByTarget,
                                        );
                                    final bookingCardSection =
                                        attached ??
                                        _buildEmptyAttachedBookingSection(
                                          section.label,
                                          bookingSection,
                                        );
                                    return Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: SizedBox(
                                        width: _columnWidthForSection(section),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (uniformBookingCardHeight !=
                                                null) ...[
                                              _buildColumnCard(
                                                bookingCardSection,
                                                backgroundColor:
                                                    StatusPalette.forDateGroup(
                                                      isToday: isToday,
                                                      isTomorrow: isTomorrow,
                                                      otherwise:
                                                          StatusPalette.grey,
                                                    ).background,
                                                borderColor:
                                                    StatusPalette.forDateGroup(
                                                      isToday: isToday,
                                                      isTomorrow: isTomorrow,
                                                      otherwise:
                                                          StatusPalette.grey,
                                                    ).border,
                                                fixedHeight:
                                                    uniformBookingCardHeight,
                                              ),
                                              const SizedBox(height: 8),
                                            ],
                                            _buildColumnCard(section),
                                          ],
                                        ),
                                      ),
                                    );
                                  }),
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  final rowPalette = StatusPalette.forDateGroup(
                    isToday: isToday,
                    isTomorrow: isTomorrow,
                  );
                  return Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    decoration: BoxDecoration(
                      color: rowPalette.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: rowPalette.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // シフト(左) + ZAIKI(右)を横並び。
                        // ZAIKI側はカードを縦に積み、シフトが長い場合は縦スクロール。
                        // ZAIKI/OSAKA機材パネルは基本非表示。トグルONの時だけ表示する。
                        if (!_showZaikiPanel)
                          shiftPanel
                        else
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: shiftPanel),
                                const SizedBox(
                                  width: 16,
                                  child: Center(
                                    child: VerticalDivider(
                                      thickness: 1,
                                      color: Color(0xFFFFE0CC),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    physics: const ClampingScrollPhysics(),
                                    child: _buildZaikiDayPanel(
                                      zaikiDay,
                                      isToday,
                                      isTomorrow,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
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
