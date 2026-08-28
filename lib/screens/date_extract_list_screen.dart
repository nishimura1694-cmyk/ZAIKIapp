part of '../main.dart';

// --- 日付抽出ビュー ---
class DateExtractListScreen extends StatefulWidget {
  const DateExtractListScreen({super.key});

  @override
  State<DateExtractListScreen> createState() => _DateExtractListScreenState();
}

class _DateColumnSection {
  final String label;
  final List<String> values;
  final bool isBookingCard;

  const _DateColumnSection({
    required this.label,
    required this.values,
    this.isBookingCard = false,
  });
}

class _DateExtractListScreenState extends State<DateExtractListScreen>
    with AutomaticKeepAliveClientMixin {
  late Future<List<_ExtractedDateRow>> _dateRowsFuture;
  final List<ScrollController> _rowHorizontalControllers = [];
  bool _syncingHorizontalScroll = false;
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
    _dateRowsFuture = _fetchDateRowsFromCsv();
  }

  @override
  void dispose() {
    for (final c in _rowHorizontalControllers) {
      c.dispose();
    }
    super.dispose();
  }

  ScrollController _getOrCreateRowController(int index) {
    while (_rowHorizontalControllers.length <= index) {
      final controller = ScrollController();
      final idx = _rowHorizontalControllers.length;
      controller.addListener(() {
        if (_syncingHorizontalScroll) return;
        if (!controller.hasClients) return;
        _syncingHorizontalScroll = true;
        final offset = controller.offset;
        for (var i = 0; i < _rowHorizontalControllers.length; i++) {
          if (i == idx) continue;
          final other = _rowHorizontalControllers[i];
          if (other.hasClients &&
              other.position.maxScrollExtent > 0 &&
              other.offset != offset) {
            other.jumpTo(offset.clamp(0.0, other.position.maxScrollExtent));
          }
        }
        _syncingHorizontalScroll = false;
      });
      _rowHorizontalControllers.add(controller);
    }
    return _rowHorizontalControllers[index];
  }

  @override
  void reassemble() {
    super.reassemble();
    _dateRowsFuture = _fetchDateRowsFromCsv();
  }

  Future<void> _reload() async {
    setState(() {
      _dateRowsFuture = _fetchDateRowsFromCsv();
    });
    await _dateRowsFuture;
  }

  @override
  bool get wantKeepAlive => true;

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

  bool _bookingValueMatchesFilter(String keyword, String value) {
    return _normalizeBookingMatchText(
      value,
    ).contains(_normalizeBookingMatchText(keyword));
  }

  bool _sectionLabelMatchesTarget(String sectionLabel, String targetLabel) {
    return _normalizeBookingMatchText(
      sectionLabel,
    ).contains(_normalizeBookingMatchText(targetLabel));
  }

  String _buildBookingSectionLabel(String bookingLabel, String filterLabel) {
    final normalizedBookingLabel = bookingLabel.trim();
    final normalizedFilterLabel = filterLabel.trim();
    if (normalizedFilterLabel.isEmpty) return normalizedBookingLabel;
    if (normalizedBookingLabel.contains(normalizedFilterLabel)) {
      return normalizedBookingLabel;
    }
    return '$normalizedFilterLabel$normalizedBookingLabel';
  }

  Map<String, _DateColumnSection> _buildBookingSectionsByTarget(
    _DateColumnSection? bookingSection,
  ) {
    if (bookingSection == null) return const <String, _DateColumnSection>{};

    const bookingTargetByFilter = <String, String>{
      'トラ・オペ': 'トラポ予約',
      'ZAIKI倉庫店頭': '店頭予約・業務',
      'OSAKA店頭': 'TODO',
    };

    final sections = <String, _DateColumnSection>{};
    for (final entry in bookingTargetByFilter.entries) {
      final matchedValues = bookingSection.values
          .where((value) => _bookingValueMatchesFilter(entry.key, value))
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
        .expand((section) => section.values)
        .toSet();
    final remainingValues = bookingSection.values
        .where((value) => !attachedValues.contains(value))
        .toList(growable: false);
    if (remainingValues.isEmpty) return null;

    return _DateColumnSection(
      label: bookingSection.label,
      values: remainingValues,
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

    final normalizedSectionLabel = _normalizeBookingMatchText(section.label);
    for (final label in _bookingTitleOnlyLabels) {
      if (normalizedSectionLabel.contains(_normalizeBookingMatchText(label))) {
        return label;
      }
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

  String _formatSectionValueForDisplay(
    _DateColumnSection section,
    String value,
  ) {
    final normalized = _sanitizeSectionValueForDisplay(section, value);
    if (!section.isBookingCard) return normalized;

    return normalized
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  double _columnWidthForSection(_DateColumnSection section) {
    final normalizedLabel = section.label.toLowerCase().replaceAll(
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

    return compactKeywords.any(normalizedLabel.contains)
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
    var estimatedHeight =
        verticalPadding +
        _measureTextHeight(context, section.label, labelStyle, contentWidth) +
        labelGap;

    if (section.values.isEmpty) {
      return estimatedHeight < minHeight ? minHeight : estimatedHeight;
    }

    for (var i = 0; i < section.values.length; i++) {
      estimatedHeight += _measureTextHeight(
        context,
        _formatSectionValueForDisplay(section, section.values[i]),
        bodyStyle,
        contentWidth,
      );
      if (i < section.values.length - 1) {
        estimatedHeight += itemSpacing;
      }
    }

    return estimatedHeight < minHeight ? minHeight : estimatedHeight;
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

    var maxHeight = 0.0;
    for (final section in bookingSections) {
      final estimatedHeight = _estimateBookingCardHeight(context, section);
      if (estimatedHeight > maxHeight) {
        maxHeight = estimatedHeight;
      }
    }
    return maxHeight + 8;
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

            for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
              final line = lines[lineIndex];
              final trimmedLine = line.trim();
              final hasCancelKeyword = line.contains('キャン');
              final isContinuationLine = continuationPattern.hasMatch(
                trimmedLine,
              );

              if (section.isBookingCard) {
                if (trimmedLine.isEmpty) {
                  // Keep the current block state across blank lines.
                } else if (hasCancelKeyword) {
                  canceledBookingBlock = true;
                } else if (!isContinuationLine) {
                  canceledBookingBlock = false;
                }
              }

              final isCanceledLine = section.isBookingCard
                  ? (hasCancelKeyword ||
                        (canceledBookingBlock && isContinuationLine))
                  : hasCancelKeyword;

              spans.add(
                TextSpan(
                  text: section.isBookingCard ? trimmedLine : line,
                  style: TextStyle(
                    decoration: isCanceledLine
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              );
              if (lineIndex < lines.length - 1) {
                spans.add(const TextSpan(text: '\n'));
              }
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(title: const Text('シフト')),
      body: SelectionArea(
        child: FutureBuilder<List<_ExtractedDateRow>>(
          future: _dateRowsFuture,
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
                        '日付データの読み込みに失敗しました\n${snapshot.error}',
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

            final rows = snapshot.data ?? const <_ExtractedDateRow>[];
            final now = DateTime.now();
            final threshold = DateTime(now.year, now.month, now.day);
            final visibleRows = rows
                .where((row) => !row.date.isBefore(threshold))
                .toList(growable: false);
            if (visibleRows.isEmpty) {
              return RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 220),
                    Center(child: Text('表示できる日付データがありません')),
                  ],
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                itemCount: visibleRows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final row = visibleRows[index];
                  final sections = _buildColumnSections(row);
                  final today = DateTime.now();
                  final tomorrow = today.add(const Duration(days: 1));
                  final isToday =
                      row.date.year == today.year &&
                      row.date.month == today.month &&
                      row.date.day == today.day;
                  final isTomorrow =
                      row.date.year == tomorrow.year &&
                      row.date.month == tomorrow.month &&
                      row.date.day == tomorrow.day;
                  final bookingSection = sections
                      .where((section) => section.isBookingCard)
                      .cast<_DateColumnSection?>()
                      .firstWhere(
                        (section) => section != null,
                        orElse: () => null,
                      );
                  final bookingSectionsByTarget = _buildBookingSectionsByTarget(
                    bookingSection,
                  );
                  final remainingBookingSection = _buildRemainingBookingSection(
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
                      .where((section) => !section.isBookingCard)
                      .toList(growable: false);
                  final dateLabel = DateFormat(
                    'M月d日(E)',
                    'ja',
                  ).format(row.date);
                  final rowHorizontalController = _getOrCreateRowController(
                    index,
                  );
                  return Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEEEEEE)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dateLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (remainingBookingSection != null) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: _buildColumnCard(
                              remainingBookingSection,
                              backgroundColor: isToday
                                  ? const Color(0xFFE3F2FD)
                                  : isTomorrow
                                  ? const Color(0xFFFFF59D)
                                  : const Color(0xFFF3F3F3),
                              borderColor: isToday
                                  ? const Color(0xFF64B5F6)
                                  : isTomorrow
                                  ? const Color(0xFFFFE082)
                                  : const Color(0xFFDADADA),
                              fixedHeight: uniformBookingCardHeight,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          controller: rowHorizontalController,
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
                                        if (uniformBookingCardHeight != null)
                                          SizedBox(
                                            height:
                                                uniformBookingCardHeight + 8,
                                          ),
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
                                    final attachedBookingSection =
                                        _findAttachedBookingSection(
                                          section.label,
                                          bookingSectionsByTarget,
                                        );
                                    final bookingCardSection =
                                        attachedBookingSection ??
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
                                                backgroundColor: isToday
                                                    ? const Color(0xFFE3F2FD)
                                                    : isTomorrow
                                                    ? const Color(0xFFFFF59D)
                                                    : const Color(0xFFF3F3F3),
                                                borderColor: isToday
                                                    ? const Color(0xFF64B5F6)
                                                    : isTomorrow
                                                    ? const Color(0xFFFFE082)
                                                    : const Color(0xFFDADADA),
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
