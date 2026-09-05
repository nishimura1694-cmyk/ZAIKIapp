part of '../main.dart';

String _normalizeCsvDisplayText(String input) {
  if (input.isEmpty) return input;

  final buffer = StringBuffer();
  for (var index = 0; index < input.length; index++) {
    final current = input[index];
    if (index + 1 < input.length) {
      final pair = '$current${input[index + 1]}';
      final combined = _halfwidthKanaDigraphMap[pair];
      if (combined != null) {
        buffer.write(combined);
        index++;
        continue;
      }
    }
    buffer.write(_halfwidthKanaMap[current] ?? current);
  }

  return buffer.toString();
}

String _decodeCsvBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

String _stripEstimateMonthPrefix(String value) {
  return value.replaceFirst(RegExp(r'^\s*\d{1,2}\s*月\s*'), '').trim();
}

Future<List<_CsvBookingRow>> _fetchCsvBookingRows() async {
  final response = await http.get(Uri.parse(_bookingCsvUrl));
  if (response.statusCode != 200) {
    throw Exception('CSVの取得に失敗しました (status: ${response.statusCode})');
  }

  final csvText = _decodeCsvBytes(response.bodyBytes);
  final records = _parseCsvRecords(csvText);
  if (records.isEmpty) return const [];

  final rows = <_CsvBookingRow>[];
  for (final record in records) {
    if (record.isEmpty) continue;

    final fourthColumn = record.length > 3
        ? _stripEstimateMonthPrefix(_normalizeCsvDisplayText(record[3].trim()))
        : '';
    final fifthColumn = record.length > 4
        ? _stripEstimateMonthPrefix(_normalizeCsvDisplayText(record[4].trim()))
        : '';

    if (fourthColumn.isEmpty && fifthColumn.isEmpty) {
      continue;
    }

    rows.add(
      _CsvBookingRow(fourthColumn: fourthColumn, fifthColumn: fifthColumn),
    );
  }

  return rows;
}

String _normalizeToMmddToken(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';

  final compactMatch = RegExp(r'^(\d{2})(\d{2})(?:\D.*)?$').firstMatch(trimmed);
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

  final jpMatch = RegExp(
    r'^(\d{1,2})\s*月\s*(\d{1,2})\s*日(?:\D.*)?$',
  ).firstMatch(trimmed);
  if (jpMatch != null) {
    final month = int.tryParse(jpMatch.group(1)!);
    final day = int.tryParse(jpMatch.group(2)!);
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

bool _isTodayMarkerCell(String cell, DateTime today) {
  final trimmed = cell.trim();
  if (trimmed.isEmpty) return false;

  final todayDate = DateTime(today.year, today.month, today.day);
  final parsedDate = _tryParseDateFromText(trimmed);
  if (parsedDate != null) {
    final parsedOnlyDate = DateTime(
      parsedDate.year,
      parsedDate.month,
      parsedDate.day,
    );
    if (parsedOnlyDate == todayDate) {
      return true;
    }
  }

  final mmdd = _normalizeToMmddToken(trimmed);
  return mmdd.isNotEmpty && mmdd == DateFormat('MMdd').format(todayDate);
}

bool _shouldIgnoreTodayExtractedValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return true;
  final compact = trimmed.replaceAll(RegExp(r'[\s　]+'), '');
  if (compact == '日' || compact == '機材名') return true;
  final withoutCircledNumbers = _stripCircledNumberSymbols(trimmed);
  final normalized = withoutCircledNumbers.replaceAll(
    RegExp(r'[\s　,、，/／・･\-ー_]+'),
    '',
  );
  return normalized.isEmpty;
}

String _stripCircledNumberSymbols(String value) {
  return value.replaceAll(
    RegExp(
      r'[\u2460-\u2473\u24EA\u24FF\u24F5-\u24FE\u2776-\u2793\u3251-\u325F\u32B1-\u32BF]',
    ),
    '',
  );
}

String _normalizeThirdRowValue(String value) {
  final withoutCircled = _stripCircledNumberSymbols(value);
  return withoutCircled.replaceAll(RegExp(r'[\s　]+'), '').trim();
}

String _resolveThirdRowValueWithSimpleRule(
  List<String> thirdRow,
  int columnIndex,
) {
  if (columnIndex >= 0 && columnIndex < thirdRow.length) {
    final current = _normalizeThirdRowValue(thirdRow[columnIndex]);
    if (current.isNotEmpty) return current;
  }

  // Simple merged-cell heuristic: when blank, reuse the nearest non-empty
  // value on the left side of the same row.
  for (var i = columnIndex - 1; i >= 0; i--) {
    if (i >= thirdRow.length) continue;
    final candidate = _normalizeThirdRowValue(thirdRow[i]);
    if (candidate.isNotEmpty) return candidate;
  }

  return '';
}

String _normalizeHonorificVariants(String value) {
  final normalized = value
      .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return normalized;
  return normalized.replaceAllMapped(
    RegExp(r'さ[\s　]*ま|サ[\s　]*マ|様'),
    (_) => '様',
  );
}

String _stripTrailingAsteriskCount(String value) {
  if (value.isEmpty) return value;
  return value.replaceFirst(RegExp(r'\s*[\*＊]\s*\d+\s*$'), '').trim();
}

String _normalizeAsciiWidth(String value) {
  if (value.isEmpty) return value;
  return value.replaceAllMapped(RegExp(r'[０-９Ａ-Ｚａ-ｚ]'), (match) {
    final code = match.group(0)!.codeUnitAt(0);
    return String.fromCharCode(code - 0xFEE0);
  });
}

String _normalizeTodayPersonGroupingKey(String value) {
  final trimmed = value
      .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
      .trim();
  if (trimmed.isEmpty) return trimmed;

  final osakaSuffixPattern = RegExp(r'【\s*OSAKA\s*】', caseSensitive: false);
  final zaikiSuffixPattern = RegExp(r'【\s*ZAIKI\s*】', caseSensitive: false);
  final sourceSuffix = osakaSuffixPattern.hasMatch(trimmed)
      ? '【OSAKA】'
      : (zaikiSuffixPattern.hasMatch(trimmed) ? '【ZAIKI】' : '');
  final base = trimmed
      .replaceAll(osakaSuffixPattern, '')
      .replaceAll(zaikiSuffixPattern, '');
  final normalizedBase =
      _normalizeAsciiWidth(
            _stripTrailingAsteriskCount(_normalizeHonorificVariants(base)),
          )
          .toLowerCase()
          .replaceAll(RegExp(r'[・･,，、./／_\-ー]+'), '')
          .replaceAll(RegExp(r'[\s　]+'), '');

  // Unify kana notation differences (e.g. さとう / サトウ).
  final kanaNormalizedBase = _toHiragana(normalizedBase);

  return '$kanaNormalizedBase$sourceSuffix';
}

Future<List<_TodaySourceCsvRecord>> _fetchTodaySourceCsvRecordsFromUrl(
  String sourceUrl, {
  required bool isOsakaSource,
}) async {
  final response = await http.get(Uri.parse(sourceUrl));
  if (response.statusCode != 200) {
    throw Exception('本日CSVの取得に失敗しました (status: ${response.statusCode})');
  }

  final csvText = _decodeCsvBytes(response.bodyBytes);
  return _parseCsvRecords(csvText)
      .map(
        (row) => _TodaySourceCsvRecord(
          row: row
              .map((cell) => _normalizeCsvDisplayText(cell.trim()))
              .toList(growable: false),
          isOsakaSource: isOsakaSource,
        ),
      )
      .toList(growable: false);
}

Future<List<_TodaySourceCsvRecord>> _fetchMergedTodaySourceCsvRecords() async {
  const sourceConfigs = <({String url, bool isOsakaSource})>[
    (url: _todayRowsSourceCsvUrl, isOsakaSource: false),
    (url: _todayRowsSourceAdditionalCsvUrl, isOsakaSource: true),
  ];

  final results = await Future.wait(
    sourceConfigs.map((sourceConfig) async {
      try {
        return await _fetchTodaySourceCsvRecordsFromUrl(
          sourceConfig.url,
          isOsakaSource: sourceConfig.isOsakaSource,
        );
      } catch (_) {
        return const <_TodaySourceCsvRecord>[];
      }
    }),
  );

  final merged = results.expand((r) => r).toList(growable: false);

  if (merged.isEmpty) {
    throw Exception('本日CSVの取得に失敗しました');
  }

  return merged;
}

String _normalizeThirdRowGroupingValue(String value) {
  if (value.isEmpty) return value;
  final normalized = _normalizeHonorificVariants(
    _normalizeThirdRowValue(value),
  );
  if (normalized.isEmpty) return normalized;
  return normalized.replaceAllMapped(
    RegExp(r'(\d+)\s*[hHｈＨ]'),
    (match) => '${match.group(1)}h',
  );
}

String _buildSourceColumnKey({
  required bool isOsakaSource,
  required int columnIndex,
}) {
  // Normal CSV is treated as ZAIKI source, additional CSV as OSAKA source.
  final sourceToken = isOsakaSource ? 'OSAKA' : 'ZAIKI';
  return '$sourceToken:$columnIndex';
}

({bool isOsakaSource, int columnIndex}) _parseSourceColumnKey(String key) {
  final parts = key.split(':');
  if (parts.length != 2) {
    return (isOsakaSource: false, columnIndex: 0);
  }
  final isOsakaSource = parts[0].toUpperCase() == 'OSAKA';
  final columnIndex = int.tryParse(parts[1]) ?? 0;
  return (isOsakaSource: isOsakaSource, columnIndex: columnIndex);
}

DateTime? _tryParseCellToDateForReference(String cell, DateTime referenceDate) {
  final trimmed = cell.trim();
  if (trimmed.isEmpty) return null;

  final parsedDate = _tryParseDateFromText(trimmed);
  if (parsedDate != null) {
    return DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
  }

  final mmdd = _normalizeToMmddToken(trimmed);
  if (mmdd.isEmpty) return null;

  final month = int.tryParse(mmdd.substring(0, 2));
  final day = int.tryParse(mmdd.substring(2, 4));
  if (month == null || day == null) return null;

  var candidate = DateTime(referenceDate.year, month, day);
  final diff = candidate.difference(referenceDate).inDays;
  if (diff > 180) {
    candidate = DateTime(referenceDate.year - 1, month, day);
  } else if (diff < -180) {
    candidate = DateTime(referenceDate.year + 1, month, day);
  }
  return DateTime(candidate.year, candidate.month, candidate.day);
}

DateTime? _extractMatchedDateInRange(
  List<String> row,
  DateTime startDate,
  DateTime endDateExclusive,
) {
  for (final rawCell in row) {
    final cell = _normalizeCsvDisplayText(rawCell).trim();
    if (cell.isEmpty) continue;
    final date = _tryParseCellToDateForReference(cell, startDate);
    if (date == null) continue;
    if (!date.isBefore(startDate) && date.isBefore(endDateExclusive)) {
      return date;
    }
  }
  return null;
}

Future<List<_WeeklySourceDayData>> _fetchWeeklyRowsFromSourceCsv() async {
  final records = await _fetchMergedTodaySourceCsvRecords();
  if (records.isEmpty) return const [];

  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final startDate = todayDate;
  // シフトタブの表示範囲（今日から2か月先まで）に合わせる。
  final maxDate = DateTime(startDate.year, startDate.month + 2, startDate.day);
  final endDateExclusive = maxDate.add(const Duration(days: 1));
  final totalDays = endDateExclusive.difference(startDate).inDays;
  final zaikiRows = records
      .where((record) => !record.isOsakaSource)
      .map((record) => record.row)
      .toList(growable: false);
  final osakaRows = records
      .where((record) => record.isOsakaSource)
      .map((record) => record.row)
      .toList(growable: false);
  final thirdRowZaiki = zaikiRows.length > 2 ? zaikiRows[2] : const <String>[];
  final thirdRowOsaka = osakaRows.length > 2 ? osakaRows[2] : const <String>[];

  final dateByKey = <String, DateTime>{};
  final valuesByDateAndColumn = <String, Map<String, List<String>>>{};
  final seenByDateAndColumn = <String, Map<String, Set<String>>>{};

  for (var i = 0; i < totalDays; i++) {
    final date = startDate.add(Duration(days: i));
    final key = DateFormat('yyyy-MM-dd').format(date);
    dateByKey[key] = date;
    valuesByDateAndColumn[key] = <String, List<String>>{};
    seenByDateAndColumn[key] = <String, Set<String>>{};
  }

  for (final record in records) {
    final row = record.row;
    final matchedDate = _extractMatchedDateInRange(
      row,
      startDate,
      endDateExclusive,
    );
    if (matchedDate == null) continue;

    final dateKey = DateFormat('yyyy-MM-dd').format(matchedDate);
    final valuesByColumn = valuesByDateAndColumn.putIfAbsent(
      dateKey,
      () => <String, List<String>>{},
    );
    final seenValuesByColumn = seenByDateAndColumn.putIfAbsent(
      dateKey,
      () => <String, Set<String>>{},
    );

    for (var columnIndex = 0; columnIndex < row.length; columnIndex++) {
      if (columnIndex == 2) continue;
      final cell = row[columnIndex];
      final trimmed = cell.trim();
      var normalizedValue = _stripTrailingAsteriskCount(
        _normalizeHonorificVariants(trimmed),
      );
      if (normalizedValue.isNotEmpty) {
        normalizedValue = record.isOsakaSource
            ? '$normalizedValue【OSAKA】'
            : '$normalizedValue【ZAIKI】';
      }
      if (trimmed.isEmpty ||
          _isTodayMarkerCell(trimmed, matchedDate) ||
          _tryParseDateFromText(trimmed) != null ||
          _shouldIgnoreTodayExtractedValue(normalizedValue)) {
        continue;
      }
      final sourceColumnKey = _buildSourceColumnKey(
        isOsakaSource: record.isOsakaSource,
        columnIndex: columnIndex,
      );
      final seenValues = seenValuesByColumn.putIfAbsent(
        sourceColumnKey,
        () => <String>{},
      );
      if (seenValues.add(normalizedValue)) {
        valuesByColumn
            .putIfAbsent(sourceColumnKey, () => <String>[])
            .add(normalizedValue);
      }
    }
  }

  final weeklyRows = <_WeeklySourceDayData>[];
  final sortedKeys = dateByKey.keys.toList(growable: false)..sort();
  for (final key in sortedKeys) {
    final date = dateByKey[key]!;
    final valuesByColumn =
        valuesByDateAndColumn[key] ?? const <String, List<String>>{};
    final columns =
        valuesByColumn.entries
            .map((entry) {
              final parsed = _parseSourceColumnKey(entry.key);
              final columnIndex = parsed.columnIndex;
              final sourceThirdRow = parsed.isOsakaSource
                  ? (thirdRowOsaka.isNotEmpty ? thirdRowOsaka : thirdRowZaiki)
                  : (thirdRowZaiki.isNotEmpty ? thirdRowZaiki : thirdRowOsaka);
              final thirdRowValue = _normalizeThirdRowGroupingValue(
                _resolveThirdRowValueWithSimpleRule(
                  sourceThirdRow,
                  columnIndex,
                ),
              );
              return _TodaySourceColumnData(
                columnIndex: columnIndex,
                thirdRowValue: thirdRowValue,
                todayValues: entry.value,
              );
            })
            .toList(growable: false)
          ..sort((a, b) => a.columnIndex.compareTo(b.columnIndex));

    weeklyRows.add(_WeeklySourceDayData(date: date, columns: columns));
  }

  return weeklyRows;
}

// 年付き完全日付のみ解析（YYYY/MM/DD, YYYYMMDD, YYYY年MM月DD日 — 時刻範囲"8-11"等は除外）
DateTime? _tryParseFullDateFromText(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final normalized = text
      .replaceAll('／', '/')
      .replaceAll('－', '-')
      .replaceAll('　', ' ')
      .replaceAll('年', '-')
      .replaceAll('月', '-')
      .replaceAll('日', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final compactMatch = RegExp(
    r'^(\d{4})(\d{2})(\d{2})$',
  ).firstMatch(normalized);
  if (compactMatch != null) {
    final y = int.tryParse(compactMatch.group(1)!);
    final m = int.tryParse(compactMatch.group(2)!);
    final d = int.tryParse(compactMatch.group(3)!);
    if (y != null && m != null && d != null) {
      try {
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }
  }

  // 非数字の末尾（曜日名など）も許容
  final fullDateMatch = RegExp(
    r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:\D.*)?$',
  ).firstMatch(normalized);
  if (fullDateMatch != null) {
    final y = int.tryParse(fullDateMatch.group(1)!);
    final m = int.tryParse(fullDateMatch.group(2)!);
    final d = int.tryParse(fullDateMatch.group(3)!);
    if (y != null && m != null && d != null) {
      try {
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }
  }

  return null;
}

DateTime? _tryParseDateFromText(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final normalized = text
      .replaceAll('／', '/')
      .replaceAll('－', '-')
      .replaceAll('　', ' ')
      .replaceAll('年', '-')
      .replaceAll('月', '-')
      .replaceAll('日', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final compactMatch = RegExp(
    r'^(\d{4})(\d{2})(\d{2})$',
  ).firstMatch(normalized);
  if (compactMatch != null) {
    final y = int.tryParse(compactMatch.group(1)!);
    final m = int.tryParse(compactMatch.group(2)!);
    final d = int.tryParse(compactMatch.group(3)!);
    if (y != null && m != null && d != null) {
      try {
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }
  }

  final fullDateMatch = RegExp(
    r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T].*)?$',
  ).firstMatch(normalized);
  if (fullDateMatch != null) {
    final y = int.tryParse(fullDateMatch.group(1)!);
    final m = int.tryParse(fullDateMatch.group(2)!);
    final d = int.tryParse(fullDateMatch.group(3)!);
    if (y != null && m != null && d != null) {
      try {
        return DateTime(y, m, d);
      } catch (_) {
        return null;
      }
    }
  }

  final monthDayMatch = RegExp(
    r'^(\d{1,2})[-/](\d{1,2})(?:[ T].*)?$',
  ).firstMatch(normalized);
  if (monthDayMatch != null) {
    final m = int.tryParse(monthDayMatch.group(1)!);
    final d = int.tryParse(monthDayMatch.group(2)!);
    if (m != null && d != null) {
      try {
        return DateTime(DateTime.now().year, m, d);
      } catch (_) {
        return null;
      }
    }
  }

  final fallback = DateTime.tryParse(normalized);
  if (fallback != null) {
    return DateTime(fallback.year, fallback.month, fallback.day);
  }

  return null;
}

double? _tryParseNumberFromText(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  final normalized = trimmed
      .replaceAll('０', '0')
      .replaceAll('１', '1')
      .replaceAll('２', '2')
      .replaceAll('３', '3')
      .replaceAll('４', '4')
      .replaceAll('５', '5')
      .replaceAll('６', '6')
      .replaceAll('７', '7')
      .replaceAll('８', '8')
      .replaceAll('９', '9')
      .replaceAll('．', '.')
      .replaceAll(',', '');
  final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(normalized);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}

int _compareNumericText(String a, String b) {
  final aNum = _tryParseNumberFromText(a);
  final bNum = _tryParseNumberFromText(b);
  if (aNum != null && bNum != null) {
    final numCompare = aNum.compareTo(bNum);
    if (numCompare != 0) return numCompare;
  } else if (aNum != null) {
    return -1;
  } else if (bNum != null) {
    return 1;
  }
  return a.compareTo(b);
}

List<String> _splitCellValues(String input) {
  final normalized = _normalizeCsvDisplayText(
    input.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight(),
  );
  if (normalized.trim().isEmpty) {
    return const [];
  }
  // Keep the original blank lines inside each CSV cell so the displayed layout
  // matches the source text as closely as possible.
  return [normalized];
}

Future<List<_ExtractedDateRow>> _fetchDateRowsFromCsv() async {
  // 見積一覧確認CSVは本体CSVと並行して取得し、直列往復による遅延を避ける。
  final bookingRowsFuture = _fetchCsvBookingRows();
  final response = await http.get(Uri.parse(_dateExtractCsvUrl));
  if (response.statusCode != 200) {
    throw Exception('日付CSVの取得に失敗しました (status: ${response.statusCode})');
  }

  final csvText = _decodeCsvBytes(response.bodyBytes);
  final records = _parseCsvRecords(csvText);
  if (records.isEmpty) return const [];

  String readHeaderLabel(int columnIndex, String fallback) {
    for (
      var rowIndex = 3;
      rowIndex < records.length && rowIndex <= 8;
      rowIndex++
    ) {
      final row = records[rowIndex];
      if (row.length <= columnIndex) continue;
      final value = row[columnIndex]
          .split(RegExp(r'\r?\n'))
          .map((e) => _normalizeCsvDisplayText(e.trim()))
          .firstWhere((e) => e.isNotEmpty, orElse: () => '');
      if (value.isNotEmpty) {
        return value;
      }
    }
    return fallback;
  }

  const baseMToTColumnOrder = <String>[
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
  ];
  const bookingColumnKey = '__BOOKING__';
  final mToTColumnOrder = <String>[...baseMToTColumnOrder, bookingColumnKey];
  const nToTColumnKeys = <String>{'N', 'O', 'P', 'Q', 'R', 'S', 'T'};
  const mToTColumnIndexes = <String, int>{
    'L': 11,
    'M': 12,
    'N': 13,
    'O': 14,
    'P': 15,
    'Q': 16,
    'R': 17,
    'S': 18,
    'T': 19,
  };
  final kColumnLabel = readHeaderLabel(10, 'K列');
  final mToTLabelsByKey = {
    for (final key in baseMToTColumnOrder)
      key: readHeaderLabel(mToTColumnIndexes[key]!, '$key列'),
    bookingColumnKey: '見積一覧',
  };

  final dateByKey = <String, DateTime>{};
  final kValuesByDateKey = <String, List<String>>{};
  final mToTValuesByDateKey = <String, Map<String, List<String>>>{};
  const kColumnIndex = 10; // K列(0-based)

  for (final record in records) {
    final kColumnText = record.length > kColumnIndex
        ? _normalizeCsvDisplayText(record[kColumnIndex].trim())
        : '';
    final mToTValuesInRecord = <String, List<String>>{};
    mToTColumnIndexes.forEach((key, index) {
      final value = record.length > index ? record[index].trim() : '';
      if (value.isNotEmpty) {
        final splitValues = _splitCellValues(value);
        if (splitValues.isNotEmpty) {
          mToTValuesInRecord[key] = splitValues;
        }
      }
    });

    for (final cell in record) {
      final trimmed = cell.trim();
      if (trimmed.isEmpty) continue;
      // 年付き完全日付のみ受け付ける（"8-11"などの時刻範囲を誤解析しないよう）
      final parsed = _tryParseFullDateFromText(trimmed);
      if (parsed == null) continue;

      final dateKey = DateFormat('yyyy-MM-dd').format(parsed);
      dateByKey.putIfAbsent(dateKey, () => parsed);
      if (kColumnText.isNotEmpty) {
        kValuesByDateKey
            .putIfAbsent(dateKey, () => <String>[])
            .add(kColumnText);
      }
      if (mToTValuesInRecord.isNotEmpty) {
        final perDate = mToTValuesByDateKey.putIfAbsent(
          dateKey,
          () => <String, List<String>>{},
        );
        mToTValuesInRecord.forEach((key, values) {
          perDate.putIfAbsent(key, () => <String>[]).addAll(values);
        });
      }
    }
  }

  String normalizeToMmdd(String value) {
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

  DateTime? bookingRowDate(_CsvBookingRow row) {
    final leftMmdd = normalizeToMmdd(row.fourthColumn);
    final rightMmdd = normalizeToMmdd(row.fifthColumn);
    final mmdd = leftMmdd.isNotEmpty ? leftMmdd : rightMmdd;
    if (mmdd.isEmpty) return null;
    final month = int.parse(mmdd.substring(0, 2));
    final day = int.parse(mmdd.substring(2, 4));
    final now = DateTime.now();
    var date = DateTime(now.year, month, day);
    if (date.difference(now).inDays > 180) {
      date = DateTime(now.year - 1, month, day);
    }
    return date;
  }

  try {
    final bookingRows = await bookingRowsFuture;
    final bookingValuesByDateKey = <String, List<String>>{};

    for (final bookingRow in bookingRows) {
      final date = bookingRowDate(bookingRow);
      if (date == null) continue;

      final dateKey = DateFormat('yyyy-MM-dd').format(date);
      dateByKey.putIfAbsent(dateKey, () => date);

      final combined = [
        bookingRow.fourthColumn.trim(),
        bookingRow.fifthColumn.trim(),
      ].where((e) => e.isNotEmpty).join(' / ');
      if (combined.isEmpty) continue;

      bookingValuesByDateKey
          .putIfAbsent(dateKey, () => <String>[])
          .add(combined);
    }

    for (final entry in bookingValuesByDateKey.entries) {
      final deduped = entry.value.toSet().toList(growable: false);
      if (deduped.isEmpty) continue;
      final perDate = mToTValuesByDateKey.putIfAbsent(
        entry.key,
        () => <String, List<String>>{},
      );
      perDate[bookingColumnKey] = deduped;
    }
  } catch (_) {
    // 日付抽出一覧は本体CSVのみでも表示できるように、見積一覧確認CSV失敗時は続行する。
  }

  final rows =
      dateByKey.entries
          .map((entry) {
            final kValues = kValuesByDateKey[entry.key] ?? const <String>[];
            final perDateMToT =
                mToTValuesByDateKey[entry.key] ??
                const <String, List<String>>{};
            final sortedPerDateMToT = perDateMToT.map((key, values) {
              final copied = List<String>.from(values);
              if (nToTColumnKeys.contains(key)) {
                copied.sort(_compareNumericText);
              }
              return MapEntry(key, copied);
            });
            return _ExtractedDateRow(
              date: entry.value,
              kColumnLabel: kColumnLabel,
              kValues: List<String>.from(kValues),
              mToTColumnOrder: mToTColumnOrder,
              mToTLabelsByKey: mToTLabelsByKey,
              mToTValuesByKey: sortedPerDateMToT,
            );
          })
          .toList(growable: false)
        ..sort((a, b) => a.date.compareTo(b.date));
  final today = DateTime.now();
  final startDate = DateTime(today.year, today.month, today.day);
  // シフトタブの表示範囲（今日から2か月先まで）に合わせる。
  final maxDate = DateTime(startDate.year, startDate.month + 2, startDate.day);
  final endDateExclusive = maxDate.add(const Duration(days: 1));

  return rows
      .where((row) {
        final date = DateTime(row.date.year, row.date.month, row.date.day);
        return !date.isBefore(startDate) && date.isBefore(endDateExclusive);
      })
      .toList(growable: false);
}

bool _rowHasAnyContent(List<String> row) {
  return row.any((cell) => cell.trim().isNotEmpty);
}

const List<String> _venueAreaSectionOrder = [
  'エリア1',
  'エリア2',
  'エリア3',
  'エリア4',
  'エリア5',
];

// 市区町村+都道府県 -> エリア のマッピング（キャッシュ）
Map<String, String> _cityAreaMapping = {};
final Map<String, Map<String, String>> _prefectureCityAreaMapping = {};
Map<String, String> _prefectureAreaMapping = {};

String _normalizeAddressToken(String input) {
  return input
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('　', '')
      .replaceAll(RegExp(r'[ー\-−―‐]'), '')
      .trim();
}

const List<String> _prefectureNames = [
  '北海道',
  '青森県',
  '岩手県',
  '宮城県',
  '秋田県',
  '山形県',
  '福島県',
  '茨城県',
  '栃木県',
  '群馬県',
  '埼玉県',
  '千葉県',
  '東京都',
  '神奈川県',
  '新潟県',
  '富山県',
  '石川県',
  '福井県',
  '山梨県',
  '長野県',
  '岐阜県',
  '静岡県',
  '愛知県',
  '三重県',
  '滋賀県',
  '京都府',
  '大阪府',
  '兵庫県',
  '奈良県',
  '和歌山県',
  '鳥取県',
  '島根県',
  '岡山県',
  '広島県',
  '山口県',
  '徳島県',
  '香川県',
  '愛媛県',
  '高知県',
  '福岡県',
  '佐賀県',
  '長崎県',
  '熊本県',
  '大分県',
  '宮崎県',
  '鹿児島県',
  '沖縄県',
];

// CSVデータから市区町村->エリアのマッピングを構築
void _initializeCityAreaMapping(_VenueAreaData data) {
  _cityAreaMapping.clear();
  _prefectureCityAreaMapping.clear();
  _prefectureAreaMapping = {};
  final cityAreas = <String, Set<String>>{};
  final prefectureAreas = <String, Set<String>>{};

  for (final area in _venueAreaSectionOrder) {
    final prefectures = data.areaTables[area] ?? const {};
    for (final entry in prefectures.entries) {
      final prefecture = _normalizeAddressToken(entry.key);
      prefectureAreas.putIfAbsent(prefecture, () => <String>{}).add(area);

      final cities = entry.value;
      final cityTable = _prefectureCityAreaMapping.putIfAbsent(
        prefecture,
        () => <String, String>{},
      );

      for (final city in cities) {
        final normalizedCity = _normalizeAddressToken(city);
        if (normalizedCity.isEmpty) continue;
        cityTable[normalizedCity] = area;
        cityAreas.putIfAbsent(normalizedCity, () => <String>{}).add(area);
      }
    }
  }

  _cityAreaMapping = {
    for (final entry in cityAreas.entries)
      if (entry.value.length == 1) entry.key: entry.value.first,
  };

  _prefectureAreaMapping = {
    for (final entry in prefectureAreas.entries)
      if (entry.value.length == 1) entry.key: entry.value.first,
  };
}

String? _detectAreaFromAddress(String address) {
  final normalizedAddress = _normalizeAddressToken(address);
  if (normalizedAddress.isEmpty) return null;

  String? foundPrefecture;
  var prefectureStart = -1;
  for (final prefecture in _prefectureNames) {
    final normalizedPrefecture = _normalizeAddressToken(prefecture);
    final idx = normalizedAddress.indexOf(normalizedPrefecture);
    if (idx >= 0) {
      foundPrefecture = normalizedPrefecture;
      prefectureStart = idx;
      break;
    }
  }

  if (foundPrefecture != null) {
    final cityTable = _prefectureCityAreaMapping[foundPrefecture];
    if (cityTable != null && cityTable.isNotEmpty) {
      final start = prefectureStart + foundPrefecture.length;
      final remainder = start < normalizedAddress.length
          ? normalizedAddress.substring(start)
          : '';

      final cityCandidates = cityTable.keys.toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));

      for (final city in cityCandidates) {
        if (remainder.contains(city) || normalizedAddress.contains(city)) {
          return cityTable[city];
        }
      }
    }

    final byPrefecture = _prefectureAreaMapping[foundPrefecture];
    if (byPrefecture != null) {
      return byPrefecture;
    }
  }

  final cityCandidates = _cityAreaMapping.keys.toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final city in cityCandidates) {
    if (normalizedAddress.contains(city)) {
      return _cityAreaMapping[city];
    }
  }

  return null;
}

String _normalizeAreaSection(String rawArea) {
  final trimmed = rawArea.trim();
  final match = RegExp(r'^エリア\s*(\d+)$').firstMatch(trimmed);
  if (match == null) return 'その他';
  final number = int.tryParse(match.group(1)!);
  if (number == null || number < 1 || number > 5) return 'その他';
  return 'エリア$number';
}

bool _isPrefectureName(String value) {
  return RegExp(r'^[^、,\s]+[都道府県]$').hasMatch(value.trim());
}

List<String> _splitCityNames(String value) {
  final parts = value
      .split(RegExp(r'[、,，\n\r]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .where((e) => RegExp(r'[市区町村]').hasMatch(e))
      .where(
        (e) => !e.contains('料金') && !e.contains('時間') && !e.contains('場合'),
      );
  return parts.toList(growable: false);
}

({int areaColumnIndex, int headerRowIndex}) _findAreaColumnMeta(
  List<List<String>> records,
) {
  // Prefer a dedicated header row like "エリア" when present.
  for (var rowIndex = 0; rowIndex < records.length; rowIndex++) {
    final row = records[rowIndex];
    for (var colIndex = 0; colIndex < row.length; colIndex++) {
      final cell = row[colIndex].trim();
      if (cell.isEmpty) continue;
      if (RegExp(r'^(エリア|地域|地方|都道府県)$').hasMatch(cell)) {
        return (areaColumnIndex: colIndex, headerRowIndex: rowIndex);
      }
    }
  }

  // If the sheet starts directly with labels such as "エリア1", include that row.
  for (var rowIndex = 0; rowIndex < records.length; rowIndex++) {
    final row = records[rowIndex];
    for (var colIndex = 0; colIndex < row.length; colIndex++) {
      final cell = row[colIndex].trim();
      if (cell.isEmpty) continue;
      if (RegExp(r'^エリア\s*\d+').hasMatch(cell)) {
        return (
          areaColumnIndex: colIndex,
          headerRowIndex: rowIndex > 0 ? rowIndex - 1 : -1,
        );
      }
    }
  }

  // Final fallback for other table variants.
  for (var rowIndex = 0; rowIndex < records.length; rowIndex++) {
    final row = records[rowIndex];
    for (var colIndex = 0; colIndex < row.length; colIndex++) {
      final cell = row[colIndex].trim();
      if (cell.isEmpty) continue;
      if (RegExp(r'エリア|地域|地方|都道府県').hasMatch(cell)) {
        return (areaColumnIndex: colIndex, headerRowIndex: rowIndex);
      }
    }
  }
  return (areaColumnIndex: 0, headerRowIndex: 0);
}

Future<_VenueAreaData> _fetchVenueAreaData() async {
  final response = await http.get(Uri.parse(_venueAreaCsvUrl));
  if (response.statusCode != 200) {
    throw Exception('CSVの取得に失敗しました (status: ${response.statusCode})');
  }

  final csvText = utf8.decode(response.bodyBytes, allowMalformed: true);
  final records = _parseCsvRecords(csvText)
      .map((row) => row.map((cell) => cell.trim()).toList(growable: false))
      .toList(growable: false);
  if (records.isEmpty) {
    return const _VenueAreaData(areaTables: {});
  }

  final meta = _findAreaColumnMeta(records);
  final tables = <String, Map<String, Set<String>>>{
    for (final key in _venueAreaSectionOrder) key: <String, Set<String>>{},
  };
  final currentPrefectureByArea = <String, String>{};

  var currentArea = 'その他';

  for (var i = meta.headerRowIndex + 1; i < records.length; i++) {
    final row = records[i];
    if (!_rowHasAnyContent(row)) continue;

    final area = meta.areaColumnIndex < row.length
        ? row[meta.areaColumnIndex].trim()
        : '';
    if (area.isNotEmpty) {
      currentArea = _normalizeAreaSection(area);
    }

    final prefectureCell = row.length > 3 ? row[3].trim() : '';
    final cityCell = row.length > 4 ? row[4].trim() : '';

    String activePrefecture = currentPrefectureByArea[currentArea] ?? '';
    if (_isPrefectureName(prefectureCell)) {
      activePrefecture = prefectureCell;
      currentPrefectureByArea[currentArea] = activePrefecture;
    }

    if (activePrefecture.isEmpty) continue;

    final cityNames = _splitCityNames(cityCell);
    final prefectureTable = tables[currentArea]!;
    final citySet = prefectureTable.putIfAbsent(
      activePrefecture,
      () => <String>{},
    );
    citySet.addAll(cityNames);
  }

  final areaTables = <String, Map<String, List<String>>>{};
  for (final area in _venueAreaSectionOrder) {
    final prefectures = tables[area] ?? const <String, Set<String>>{};
    areaTables[area] = {
      for (final entry in prefectures.entries)
        entry.key: entry.value.toList(growable: false),
    };
  }

  return _VenueAreaData(areaTables: areaTables);
}

List<List<String>> _parseCsvRecords(String input) {
  final rows = <List<String>>[];
  final row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final char = input[i];

    if (char == '"') {
      final hasNext = i + 1 < input.length;
      if (inQuotes && hasNext && input[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char == ',' && !inQuotes) {
      row.add(cell.toString());
      cell.clear();
      continue;
    }

    if ((char == '\n' || char == '\r') && !inQuotes) {
      if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') {
        i++;
      }
      row.add(cell.toString());
      cell.clear();
      rows.add(List<String>.from(row));
      row.clear();
      continue;
    }

    cell.write(char);
  }

  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(List<String>.from(row));
  }

  return rows;
}

Future<SharedPreferences> _getSharedPreferencesInstance() {
  return _sharedPreferencesFuture ??= SharedPreferences.getInstance();
}

dynamic _toJsonSafeValue(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Timestamp) {
    return {
      '__type': 'timestamp',
      'millisecondsSinceEpoch': value.millisecondsSinceEpoch,
    };
  }
  if (value is GeoPoint) {
    return {
      '__type': 'geopoint',
      'latitude': value.latitude,
      'longitude': value.longitude,
    };
  }
  if (value is List) {
    return value.map(_toJsonSafeValue).toList(growable: false);
  }
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(key.toString(), _toJsonSafeValue(item)),
    );
  }
  return value.toString();
}

dynamic _fromJsonSafeValue(dynamic value) {
  if (value is List) {
    return value.map(_fromJsonSafeValue).toList(growable: false);
  }
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    final type = map['__type'];
    if (type == 'timestamp') {
      final millis = (map['millisecondsSinceEpoch'] as num?)?.toInt();
      return millis == null
          ? null
          : Timestamp.fromMillisecondsSinceEpoch(millis);
    }
    if (type == 'geopoint') {
      final lat = (map['latitude'] as num?)?.toDouble();
      final lng = (map['longitude'] as num?)?.toDouble();
      return lat == null || lng == null ? null : GeoPoint(lat, lng);
    }
    return map.map((key, item) => MapEntry(key, _fromJsonSafeValue(item)));
  }
  return value;
}

List<_SearchResultDocument> _searchDocumentsFromSnapshot(
  QuerySnapshot<Map<String, dynamic>> snapshot,
) {
  return snapshot.docs
      .map(
        (doc) => _SearchResultDocument(
          id: doc.id,
          data: Map<String, dynamic>.from(doc.data()),
        ),
      )
      .toList(growable: false);
}

Future<void> _ensurePersistentSearchQueryCacheLoaded() {
  return _persistentSearchQueryCacheLoadFuture ??= () async {
    final prefs = await _getSharedPreferencesInstance();
    final raw = prefs.getString(_searchPersistentCacheStorageKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return;

      var removedExpired = false;
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final cacheEntry = _PersistedSearchCacheEntry.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (cacheEntry.isExpired) {
          removedExpired = true;
          continue;
        }
        _persistentSearchQueryCache[entry.key as String] = cacheEntry;
      }

      if (removedExpired) {
        await _persistSearchQueryCache();
      }
    } catch (e) {
      debugPrint('Failed to load persisted search cache: $e');
    }
  }();
}

Future<void> _persistSearchQueryCache() async {
  final prefs = await _getSharedPreferencesInstance();
  final payload = _persistentSearchQueryCache.map(
    (key, entry) => MapEntry(key, entry.toJson()),
  );
  await prefs.setString(_searchPersistentCacheStorageKey, json.encode(payload));
}

void _storePersistedSearchQueryCache(
  String cacheKey,
  List<_SearchResultDocument> docs,
) {
  _persistentSearchQueryCache[cacheKey] = _PersistedSearchCacheEntry(
    storedAtMillis: DateTime.now().millisecondsSinceEpoch,
    docs: docs,
  );
  if (_persistentSearchQueryCache.length > _searchQueryCacheMaxEntries) {
    final oldestKey = _persistentSearchQueryCache.entries
        .reduce(
          (a, b) => a.value.storedAtMillis <= b.value.storedAtMillis ? a : b,
        )
        .key;
    _persistentSearchQueryCache.remove(oldestKey);
  }
  unawaited(_persistSearchQueryCache());
}

String _buildSearchCacheKey({
  required String namespace,
  required String query,
  required int limit,
}) {
  return '$namespace|$limit|${_normalizeSearchTextCached(query)}';
}

void _invalidateSearchQueryCache({String? namespace}) {
  if (namespace == null) {
    _searchQueryCache.clear();
    unawaited(_invalidatePersistentSearchQueryCache());
    return;
  }

  final keysToRemove = _searchQueryCache.keys
      .where((key) => key.startsWith('$namespace|'))
      .toList(growable: false);
  for (final key in keysToRemove) {
    _searchQueryCache.remove(key);
  }

  unawaited(_invalidatePersistentSearchQueryCache(namespace: namespace));
}

Future<void> _invalidatePersistentSearchQueryCache({String? namespace}) async {
  await _ensurePersistentSearchQueryCacheLoaded();
  if (namespace == null) {
    _persistentSearchQueryCache.clear();
    await _persistSearchQueryCache();
    return;
  }

  final keysToRemove = _persistentSearchQueryCache.keys
      .where((key) => key.startsWith('$namespace|'))
      .toList(growable: false);
  if (keysToRemove.isEmpty) return;

  for (final key in keysToRemove) {
    _persistentSearchQueryCache.remove(key);
  }
  await _persistSearchQueryCache();
}

Stream<List<_SearchResultDocument>> _buildIndexedSearchStream({
  required String cacheNamespace,
  required CollectionReference<Map<String, dynamic>> collection,
  required String searchQuery,
  required int idleLimit,
  required int searchLimit,
  required Query<Map<String, dynamic>> Function(
    CollectionReference<Map<String, dynamic>> collection,
    int limit,
  )
  fallbackQueryBuilder,
}) {
  final trimmedQuery = searchQuery.trim();
  final fallbackLimit = trimmedQuery.isEmpty ? idleLimit : searchLimit;
  final fallbackQuery = fallbackQueryBuilder(collection, fallbackLimit);
  final serverTerm = _extractServerSearchTerm(trimmedQuery);

  if (trimmedQuery.isEmpty || serverTerm == null) {
    return fallbackQuery.snapshots().map(_searchDocumentsFromSnapshot);
  }

  final cacheKey = _buildSearchCacheKey(
    namespace: cacheNamespace,
    query: trimmedQuery,
    limit: searchLimit,
  );
  final cachedFuture = _searchQueryCache.putIfAbsent(cacheKey, () async {
    await _ensurePersistentSearchQueryCacheLoaded();
    final persisted = _persistentSearchQueryCache[cacheKey];
    if (persisted != null && !persisted.isExpired) {
      return persisted.docs;
    }

    final indexedSnapshot = await collection
        .where('searchPrefixes', arrayContains: serverTerm)
        .limit(searchLimit)
        .get();
    final indexedDocs = _searchDocumentsFromSnapshot(indexedSnapshot);
    final fallbackDocs = _searchDocumentsFromSnapshot(
      await fallbackQuery.get(),
    );

    final docsById = <String, _SearchResultDocument>{
      for (final doc in indexedDocs) doc.id: doc,
    };
    for (final doc in fallbackDocs) {
      docsById.putIfAbsent(doc.id, () => doc);
      if (docsById.length >= searchLimit) {
        break;
      }
    }

    final docs = docsById.values.toList(growable: false);
    _storePersistedSearchQueryCache(cacheKey, docs);
    return docs;
  });

  if (_searchQueryCache.length > _searchQueryCacheMaxEntries) {
    _searchQueryCache.remove(_searchQueryCache.keys.first);
  }

  return Stream.fromFuture(cachedFuture);
}

Map<String, dynamic> _buildVenueSearchIndex(
  String name, {
  String? shopAndRoom,
}) {
  final source = '${name.trim()} ${(shopAndRoom ?? '').trim()}'.trim();
  return {
    'searchText': _normalizeSearchText(source),
    'searchPrefixes': _buildSearchPrefixes(source),
  };
}

Map<String, dynamic> _buildBookingSearchIndex({
  required String customerName,
  required String venueName,
}) {
  final source = '${customerName.trim()} ${venueName.trim()}'.trim();
  return {
    'searchText': _normalizeSearchText(source),
    'searchPrefixes': _buildSearchPrefixes(source),
  };
}

String _toHiragana(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x30A1 && rune <= 0x30F6) {
      buffer.writeCharCode(rune - 0x60);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isSubsequenceMatch(String target, String query) {
  if (query.isEmpty) return true;
  var queryIndex = 0;
  for (var i = 0; i < target.length; i++) {
    if (target.codeUnitAt(i) == query.codeUnitAt(queryIndex)) {
      queryIndex++;
      if (queryIndex == query.length) return true;
    }
  }
  return false;
}

bool _isWithinEditDistanceOne(String a, String b) {
  final lenA = a.length;
  final lenB = b.length;
  if ((lenA - lenB).abs() > 1) return false;

  var i = 0;
  var j = 0;
  var edits = 0;

  while (i < lenA && j < lenB) {
    if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
      i++;
      j++;
      continue;
    }

    edits++;
    if (edits > 1) return false;

    if (lenA > lenB) {
      i++;
    } else if (lenB > lenA) {
      j++;
    } else {
      i++;
      j++;
    }
  }

  if (i < lenA || j < lenB) {
    edits++;
  }

  return edits <= 1;
}

bool _isFuzzyTermMatchConfigurable(
  String target,
  String term, {
  required bool enableSubsequence,
  required bool enableEditDistance,
  List<String>? preSplitWords,
}) {
  if (target.contains(term)) return true;

  if (term.length <= 2) return false;

  if (enableSubsequence && _isSubsequenceMatch(target, term)) return true;

  if (enableEditDistance && term.length >= 4) {
    final words = preSplitWords ?? target.split(_searchWordSplitPattern);
    for (final word in words) {
      if (word.isEmpty) continue;
      if ((word.length - term.length).abs() > 1) continue;
      if (_isWithinEditDistanceOne(word, term)) return true;
    }
  }

  return false;
}

bool _isKanaOnly(String value) {
  var hasKana = false;
  for (final rune in value.runes) {
    if (rune >= 0x3040 && rune <= 0x30FF) {
      hasKana = true;
      continue;
    }
    if (rune == 0x20) {
      continue;
    }
    return false;
  }
  return hasKana;
}

bool Function(String target) _createFuzzyMatcher(
  String query, {
  bool enableSubsequence = true,
  bool enableEditDistance = true,
}) {
  final normalizedQuery = _normalizeSearchTextCached(query);
  if (normalizedQuery.isEmpty) return (_) => true;
  final allowFuzzyMatch = _isKanaOnly(normalizedQuery);
  final useSubsequence = allowFuzzyMatch && enableSubsequence;
  final useEditDistance = allowFuzzyMatch && enableEditDistance;

  final terms = normalizedQuery
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  return (target) {
    final normalizedTarget = _normalizeSearchTextCached(target);
    if (normalizedTarget.contains(normalizedQuery)) return true;
    // 単語が1つだけの場合は上のcontainsチェックと同じ結果になるため、
    // 複数語のクエリ(語順や項目をまたぐ入力)の場合のみ、語ごとのAND一致を試みる。
    if (terms.length <= 1) return false;
    final targetWords = useEditDistance
        ? normalizedTarget.split(_searchWordSplitPattern)
        : null;
    return terms.every(
      (term) => _isFuzzyTermMatchConfigurable(
        normalizedTarget,
        term,
        enableSubsequence: useSubsequence,
        enableEditDistance: useEditDistance,
        preSplitWords: targetWords,
      ),
    );
  };
}

List<String> _extractVenueAttentionItems(Map<String, dynamic> data) {
  final rawItems = (data['attentionItems'] as List?) ?? const [];
  final legacy = (data['attentionNote'] ?? '').toString().trim();
  final cacheKey = '${rawItems.join('||')}::$legacy';
  final cached = _attentionItemsCache[cacheKey];
  if (cached != null) return cached;

  final items =
      (data['attentionItems'] as List?)
          ?.map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList() ??
      [];
  if (items.isNotEmpty) {
    items.sort();
    if (_attentionItemsCache.length >= _parsedFieldCacheMaxEntries) {
      _attentionItemsCache.remove(_attentionItemsCache.keys.first);
    }
    _attentionItemsCache[cacheKey] = items;
    return items;
  }

  // Backward compatibility for older docs.
  if (legacy.isEmpty) return const [];

  final parsed = legacy
      .split(RegExp(r'[\n、,/]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();
  parsed.sort();
  if (_attentionItemsCache.length >= _parsedFieldCacheMaxEntries) {
    _attentionItemsCache.remove(_attentionItemsCache.keys.first);
  }
  _attentionItemsCache[cacheKey] = parsed;
  return parsed;
}

String _extractVenueExtraChargeNote(Map<String, dynamic> data) {
  final note = (data['extraChargeNote'] ?? '').toString().trim();
  if (note.isNotEmpty) return note;

  final rawItems = (data['extraChargeItems'] as List?) ?? const [];
  final cacheKey = rawItems.join('||');
  final cached = _extraChargeNoteCache[cacheKey];
  if (cached != null) return cached;

  // Backward compatibility for docs saved as item arrays.
  final items =
      (data['extraChargeItems'] as List?)
          ?.map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList() ??
      [];
  if (items.isEmpty) return '';
  items.sort();
  final resolved = items.join(' / ');
  if (_extraChargeNoteCache.length >= _parsedFieldCacheMaxEntries) {
    _extraChargeNoteCache.remove(_extraChargeNoteCache.keys.first);
  }
  _extraChargeNoteCache[cacheKey] = resolved;
  return resolved;
}

List<String> _extractBookingTagsFromData(Map<String, dynamic> data) {
  final tags = <String>{};

  final rawTags = data['customerTags'];
  if (rawTags is List) {
    for (final raw in rawTags) {
      final tag = raw.toString().trim();
      if (tag.isEmpty) continue;
      if (tag == 'トラ' || tag == 'オペ') {
        tags.add(tag);
      }
    }
  }

  if (data['isTra'] == true) tags.add('トラ');
  if (data['isOpe'] == true) tags.add('オペ');

  final ordered = <String>[];
  if (tags.contains('トラ')) ordered.add('トラ');
  if (tags.contains('オペ')) ordered.add('オペ');
  return ordered;
}

Widget _buildBookingTagChip(String label) {
  final isTra = label == 'トラ';
  final backgroundColor = isTra
      ? const Color(0xFFE3F2FD)
      : const Color(0xFFFFF3E0);
  final borderColor = isTra ? const Color(0xFF90CAF9) : const Color(0xFFFFCC80);
  final textColor = isTra ? const Color(0xFF1565C0) : const Color(0xFFE65100);

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: borderColor),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: textColor,
      ),
    ),
  );
}

bool _isRetrospectiveChecked(Map<String, dynamic> data) {
  // 明示的に retrospectiveChecked が設定されていればそれを優先使用
  if (data.containsKey('retrospectiveChecked')) {
    return data['retrospectiveChecked'] == true;
  }
  // 古いドキュメント用フォールバック：振り返り情報が存在すれば checked と見なす
  return (data['retrospectiveResult'] ?? '').toString().trim().isNotEmpty ||
      (data['retrospectiveIssue'] ?? '').toString().trim().isNotEmpty ||
      (data['retrospectiveSolution'] ?? '').toString().trim().isNotEmpty ||
      (data['retrospectiveNext'] ?? '').toString().trim().isNotEmpty;
}

final Map<String, Future<String>> _pdfDisplayNameFutureCache = {};

String _extractPdfFileNameFromDownloadUrl(String url) {
  try {
    final uri = Uri.parse(url);
    final objectIndex = uri.pathSegments.indexOf('o');
    if (objectIndex < 0 || objectIndex + 1 >= uri.pathSegments.length) {
      return 'PDF';
    }
    final objectPath = Uri.decodeComponent(uri.pathSegments[objectIndex + 1]);
    final fileName = objectPath.split('/').last.trim();
    return fileName.isEmpty ? 'PDF' : fileName;
  } catch (_) {
    return 'PDF';
  }
}

Future<String> _resolvePdfDisplayName(String url, {String? preferredName}) {
  final trimmedPreferredName = preferredName?.trim() ?? '';
  if (trimmedPreferredName.isNotEmpty) {
    return Future.value(trimmedPreferredName);
  }

  return _pdfDisplayNameFutureCache.putIfAbsent(url, () async {
    try {
      final ref = FirebaseStorage.instance.refFromURL(url);
      final metadata = await ref.getMetadata();
      final originalFileName =
          metadata.customMetadata?['originalFileName']?.trim() ?? '';
      if (originalFileName.isNotEmpty) {
        return originalFileName;
      }

      final fullPath = metadata.fullPath.trim();
      if (fullPath.isNotEmpty) {
        final fileName = fullPath.split('/').last.trim();
        if (fileName.isNotEmpty) return fileName;
      }

      final metadataName = metadata.name.trim();
      if (metadataName.isNotEmpty) {
        return metadataName;
      }
    } catch (_) {
      // Fall back to parsing the download URL when metadata lookup fails.
    }

    return _extractPdfFileNameFromDownloadUrl(url);
  });
}
