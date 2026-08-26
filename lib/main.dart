import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'firebase_options.dart';
import 'package:geolocator/geolocator.dart';
import 'services/booking_notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BookingNotificationService.registerBackgroundHandler();
  runApp(const VenueAppBootstrap());
}

class VenueAppBootstrap extends StatefulWidget {
  const VenueAppBootstrap({super.key});

  @override
  State<VenueAppBootstrap> createState() => _VenueAppBootstrapState();
}

class _VenueAppBootstrapState extends State<VenueAppBootstrap> {
  late final Future<FirebaseApp> _firebaseInit = Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  Future<void> _initializeNotificationsAfterFirebase() async {
    await _firebaseInit;
    await BookingNotificationService.instance.initialize();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeNotificationsAfterFirebase());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FirebaseApp>(
      future: _firebaseInit,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('初期化に失敗しました: ${snapshot.error}'),
                ),
              ),
            ),
          );
        }

        return const VenueApp();
      },
    );
  }
}

// --- モデルクラス ---
class PhotoItem {
  final String url;
  final String venueName;
  final String docId;
  final Map<String, dynamic> data;
  PhotoItem(this.url, this.venueName, this.docId, this.data);
}

const int _parsedFieldCacheMaxEntries = 1200;
final Map<String, List<String>> _attentionItemsCache = {};
final Map<String, String> _extraChargeNoteCache = {};
const int _normalizedTextCacheMaxEntries = 4000;
final Map<String, String> _normalizedTextCache = {};
final RegExp _collapseWhitespacePattern = RegExp(r'\s+');
final RegExp _searchWordSplitPattern = RegExp(r'[\s、。・/\\\-_,.()]+');
// Keep initial Firestore reads smaller so first paint happens sooner.
const int _venuePageSize = 40;
const int _bookingPageSize = 50;
const int _searchPrefixMaxLength = 24;
const int _serverSearchMinLength = 2;
const int _venueSearchCandidateLimit = 120;
const int _bookingSearchCandidateLimit = 120;
const int _venuePickerSearchCandidateLimit = 1200;
const Duration _searchPersistentCacheTtl = Duration(hours: 12);
const int _searchQueryCacheMaxEntries = 48;
const String _searchPersistentCacheStorageKey = 'search_query_cache_v2';
final Map<String, Future<List<_SearchResultDocument>>> _searchQueryCache = {};
final Map<String, _PersistedSearchCacheEntry> _persistentSearchQueryCache = {};
Future<SharedPreferences>? _sharedPreferencesFuture;
Future<void>? _persistentSearchQueryCacheLoadFuture;

class _SearchResultDocument {
  final String id;
  final Map<String, dynamic> data;

  const _SearchResultDocument({required this.id, required this.data});

  Map<String, dynamic> toJson() => {'id': id, 'data': _toJsonSafeValue(data)};

  factory _SearchResultDocument.fromJson(Map<String, dynamic> json) {
    return _SearchResultDocument(
      id: (json['id'] ?? '').toString(),
      data: Map<String, dynamic>.from(
        _fromJsonSafeValue(json['data']) as Map<dynamic, dynamic>? ??
            const <String, dynamic>{},
      ),
    );
  }
}

class _PersistedSearchCacheEntry {
  final int storedAtMillis;
  final List<_SearchResultDocument> docs;

  const _PersistedSearchCacheEntry({
    required this.storedAtMillis,
    required this.docs,
  });

  bool get isExpired {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - storedAtMillis > _searchPersistentCacheTtl.inMilliseconds;
  }

  Map<String, dynamic> toJson() => {
    'storedAtMillis': storedAtMillis,
    'docs': docs.map((doc) => doc.toJson()).toList(growable: false),
  };

  factory _PersistedSearchCacheEntry.fromJson(Map<String, dynamic> json) {
    final rawDocs = (json['docs'] as List?) ?? const [];
    return _PersistedSearchCacheEntry(
      storedAtMillis: (json['storedAtMillis'] as num?)?.toInt() ?? 0,
      docs: rawDocs
          .whereType<Map>()
          .map(
            (doc) =>
                _SearchResultDocument.fromJson(Map<String, dynamic>.from(doc)),
          )
          .toList(growable: false),
    );
  }
}

String _normalizeSearchText(String input) {
  return _toHiragana(
    input.toLowerCase().trim().replaceAll(_collapseWhitespacePattern, ' '),
  );
}

String _normalizeSearchTextCached(String input) {
  final cached = _normalizedTextCache[input];
  if (cached != null) return cached;

  final normalized = _normalizeSearchText(input);
  if (_normalizedTextCache.length >= _normalizedTextCacheMaxEntries) {
    _normalizedTextCache.remove(_normalizedTextCache.keys.first);
  }
  _normalizedTextCache[input] = normalized;
  return normalized;
}

List<String> _buildSearchPrefixes(String input) {
  final normalized = _normalizeSearchText(input);
  if (normalized.isEmpty) return const [];

  final tokens = <String>{normalized};
  tokens.addAll(
    normalized
        .split(_searchWordSplitPattern)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty),
  );

  final prefixes = <String>{};
  for (final token in tokens) {
    final maxLen = token.length < _searchPrefixMaxLength
        ? token.length
        : _searchPrefixMaxLength;
    for (var i = 1; i <= maxLen; i++) {
      prefixes.add(token.substring(0, i));
    }
  }

  final result = prefixes.toList(growable: false);
  result.sort();
  return result;
}

String? _extractServerSearchTerm(String query) {
  final normalized = _normalizeSearchTextCached(query);
  if (normalized.isEmpty) return null;
  final term = normalized
      .split(' ')
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');
  if (term.length < _serverSearchMinLength) return null;
  if (term.length <= _searchPrefixMaxLength) return term;
  return term.substring(0, _searchPrefixMaxLength);
}

String _buildVenueSearchSourceFromData(Map<String, dynamic> data) {
  return '${(data['name'] ?? '').toString()} ${(data['shopAndRoom'] ?? '').toString()}'
      .trim();
}

String _buildBookingSearchSourceFromData(Map<String, dynamic> data) {
  return '${(data['customerName'] ?? '').toString()} ${(data['venueName'] ?? '').toString()}'
      .trim();
}

const String _bookingCsvUrl =
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vTmyVYdJK3cDalO65eCCITv90nT2t-Oy4gSLCoko01mBZqQtJSloBKb6YT9UP1v_zZANusm9ohFfeGg/pub?gid=0&single=true&output=csv';
const String _venueAreaCsvUrl =
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vTcucNWj4oOEf704y27RYSZCGi_BIlnDaCHcFNwtLzdcvZhD5D9_ci3gHvAmsCLRpgioSbf3pO1KZ6b/pub?gid=0&single=true&output=csv';
const String _dateExtractCsvUrl =
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vS7xtxZoJxgreFogaeznCANvX8ySn1xwrt32QdyStCFGIsYq9DKoykCJWD1qsMXgsW7IA5cvr3tviYG/pub?output=csv';
const String _todayRowsSourceCsvUrl =
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vROAjaOGG82t-lfr_VfAplMDZiWx11E-VXnPHTH9i3EmMEetQMiDPppBmaPSZ4EJlWNj7RIuefbrRr7/pub?output=csv';
const String _todayRowsSourceAdditionalCsvUrl =
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vROAjaOGG82t-lfr_VfAplMDZiWx11E-VXnPHTH9i3EmMEetQMiDPppBmaPSZ4EJlWNj7RIuefbrRr7/pub?gid=1527229104&single=true&output=csv';

class _CsvBookingRow {
  final String fourthColumn;
  final String fifthColumn;

  const _CsvBookingRow({required this.fourthColumn, required this.fifthColumn});
}

class _ExtractedDateRow {
  final DateTime date;
  final String kColumnLabel;
  final List<String> kValues;
  final List<String> mToTColumnOrder;
  final Map<String, String> mToTLabelsByKey;
  final Map<String, List<String>> mToTValuesByKey;

  const _ExtractedDateRow({
    required this.date,
    required this.kColumnLabel,
    required this.kValues,
    required this.mToTColumnOrder,
    required this.mToTLabelsByKey,
    required this.mToTValuesByKey,
  });
}

class _VenueAreaData {
  final Map<String, Map<String, List<String>>> areaTables;

  const _VenueAreaData({required this.areaTables});
}

class _TodaySourceColumnData {
  final int columnIndex;
  final String thirdRowValue;
  final List<String> todayValues;

  const _TodaySourceColumnData({
    required this.columnIndex,
    required this.thirdRowValue,
    required this.todayValues,
  });
}

class _WeeklySourceDayData {
  final DateTime date;
  final List<_TodaySourceColumnData> columns;

  const _WeeklySourceDayData({required this.date, required this.columns});
}

class _TodaySourceCsvRecord {
  final List<String> row;
  final bool isOsakaSource;

  const _TodaySourceCsvRecord({required this.row, required this.isOsakaSource});
}

const Map<String, String> _halfwidthKanaMap = {
  '｡': '。',
  '｢': '「',
  '｣': '」',
  '､': '、',
  '･': '・',
  'ｦ': 'ヲ',
  'ｧ': 'ァ',
  'ｨ': 'ィ',
  'ｩ': 'ゥ',
  'ｪ': 'ェ',
  'ｫ': 'ォ',
  'ｬ': 'ャ',
  'ｭ': 'ュ',
  'ｮ': 'ョ',
  'ｯ': 'ッ',
  'ｰ': 'ー',
  'ｱ': 'ア',
  'ｲ': 'イ',
  'ｳ': 'ウ',
  'ｴ': 'エ',
  'ｵ': 'オ',
  'ｶ': 'カ',
  'ｷ': 'キ',
  'ｸ': 'ク',
  'ｹ': 'ケ',
  'ｺ': 'コ',
  'ｻ': 'サ',
  'ｼ': 'シ',
  'ｽ': 'ス',
  'ｾ': 'セ',
  'ｿ': 'ソ',
  'ﾀ': 'タ',
  'ﾁ': 'チ',
  'ﾂ': 'ツ',
  'ﾃ': 'テ',
  'ﾄ': 'ト',
  'ﾅ': 'ナ',
  'ﾆ': 'ニ',
  'ﾇ': 'ヌ',
  'ﾈ': 'ネ',
  'ﾉ': 'ノ',
  'ﾊ': 'ハ',
  'ﾋ': 'ヒ',
  'ﾌ': 'フ',
  'ﾍ': 'ヘ',
  'ﾎ': 'ホ',
  'ﾏ': 'マ',
  'ﾐ': 'ミ',
  'ﾑ': 'ム',
  'ﾒ': 'メ',
  'ﾓ': 'モ',
  'ﾔ': 'ヤ',
  'ﾕ': 'ユ',
  'ﾖ': 'ヨ',
  'ﾗ': 'ラ',
  'ﾘ': 'リ',
  'ﾙ': 'ル',
  'ﾚ': 'レ',
  'ﾛ': 'ロ',
  'ﾜ': 'ワ',
  'ﾝ': 'ン',
  'ﾞ': '゛',
  'ﾟ': '゜',
};

const Map<String, String> _halfwidthKanaDigraphMap = {
  'ｳﾞ': 'ヴ',
  'ｶﾞ': 'ガ',
  'ｷﾞ': 'ギ',
  'ｸﾞ': 'グ',
  'ｹﾞ': 'ゲ',
  'ｺﾞ': 'ゴ',
  'ｻﾞ': 'ザ',
  'ｼﾞ': 'ジ',
  'ｽﾞ': 'ズ',
  'ｾﾞ': 'ゼ',
  'ｿﾞ': 'ゾ',
  'ﾀﾞ': 'ダ',
  'ﾁﾞ': 'ヂ',
  'ﾂﾞ': 'ヅ',
  'ﾃﾞ': 'デ',
  'ﾄﾞ': 'ド',
  'ﾊﾞ': 'バ',
  'ﾋﾞ': 'ビ',
  'ﾌﾞ': 'ブ',
  'ﾍﾞ': 'ベ',
  'ﾎﾞ': 'ボ',
  'ﾊﾟ': 'パ',
  'ﾋﾟ': 'ピ',
  'ﾌﾟ': 'プ',
  'ﾍﾟ': 'ペ',
  'ﾎﾟ': 'ポ',
  'ﾜﾞ': 'ヷ',
  'ｦﾞ': 'ヺ',
};

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
  final endDateExclusive = startDate.add(const Duration(days: 14));
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

  for (var i = 0; i < 14; i++) {
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
    final bookingRows = await _fetchCsvBookingRows();
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
  final endDateExclusive = startDate.add(const Duration(days: 14));

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
  if (target.startsWith(term)) return true;

  final words = preSplitWords ?? target.split(_searchWordSplitPattern);
  for (final word in words) {
    if (word.isEmpty) continue;
    if (word.startsWith(term)) return true;
  }

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
    if (!allowFuzzyMatch) return false;
    final targetWords = useEditDistance
        ? normalizedTarget.split(_searchWordSplitPattern)
        : null;
    final matchedByNormalized = terms.every(
      (term) => _isFuzzyTermMatchConfigurable(
        normalizedTarget,
        term,
        enableSubsequence: useSubsequence,
        enableEditDistance: useEditDistance,
        preSplitWords: targetWords,
      ),
    );
    return matchedByNormalized;
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

class VenueApp extends StatelessWidget {
  const VenueApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color brandOrange = Color.fromARGB(255, 255, 102, 0);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZAIKIapp',
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
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.black87,
          selectionColor: Color(0xFFDDDDDD),
          selectionHandleColor: Colors.black87,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          isDense: true,
          alignLabelWithHint: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
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

String _normalizeCardMultilineText(String value) {
  return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

Widget _buildPreservedCardText(
  String value, {
  TextStyle? style,
  String emptyPlaceholder = ' ',
}) {
  final normalized = _normalizeCardMultilineText(value);
  return Text(
    normalized.trim().isEmpty ? emptyPlaceholder : normalized,
    style: style,
    softWrap: true,
  );
}

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
    _shiftNavKey,
    _venueNavKey,
    _estimateNavKey,
  ];

  void _markTabAsOpened(int index) {
    if (index == 1) _hasOpenedShiftTab = true;
    if (index == 2) _hasOpenedVenueTab = true;
    if (index == 3) _hasOpenedEstimateTab = true;
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
            _hasOpenedShiftTab ? _shiftPage : const SizedBox.shrink(),
            _hasOpenedVenueTab ? _venuePage : const SizedBox.shrink(),
            _hasOpenedEstimateTab ? _estimatePage : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: _handleTabChange,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.history), label: '履歴'),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_today),
              label: 'シフト',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.location_city),
              label: '会場',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.description), label: '見積'),
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

class OtherTabScreen extends StatelessWidget {
  const OtherTabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const linkUrl =
        'https://docs.google.com/spreadsheets/d/1bKddlZg_E9Onsn0XG99LLa_k5XPQ2o-kLQVdHmsSP58/edit?gid=0#gid=0';
    return Scaffold(
      appBar: AppBar(title: const Text('その他')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.link),
              trailing: const Icon(Icons.open_in_new),
              title: const Text('既読無視check'),
              subtitle: const Text('Googleスプレッドシートを開く'),
              onTap: () async {
                final uri = Uri.parse(linkUrl);
                if (!await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                )) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- 月次見積データ（Dropbox見積データ抽出の結果を金額を除いてアプリに反映したもの) ---
class _MonthlyEstimateItem {
  final String category;
  final String name;
  final String? memo;
  final num? qty;
  final Object? duration;

  const _MonthlyEstimateItem({
    required this.category,
    required this.name,
    this.memo,
    this.qty,
    this.duration,
  });

  factory _MonthlyEstimateItem.fromJson(Map<String, dynamic> json) {
    return _MonthlyEstimateItem(
      category: (json['category'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      memo: json['memo']?.toString(),
      qty: json['qty'] as num?,
      duration: json['duration'],
    );
  }

  String get qtyDurationLabel {
    final parts = <String>[];
    if (qty != null) parts.add('数量:$qty');
    if (duration != null) parts.add('${duration}');
    return parts.join(' / ');
  }
}

class _MonthlyEstimateJob {
  final String folder;
  final String? clientName;
  final String? deliveryAddress;
  final String? deliveryDate;
  final String? time;
  final String? returnTime;
  final String? note;
  final List<_MonthlyEstimateItem> items;

  const _MonthlyEstimateJob({
    required this.folder,
    this.clientName,
    this.deliveryAddress,
    this.deliveryDate,
    this.time,
    this.returnTime,
    this.note,
    required this.items,
  });

  factory _MonthlyEstimateJob.fromJson(Map<String, dynamic> json) {
    final itemsJson = (json['items'] as List?) ?? const [];
    return _MonthlyEstimateJob(
      folder: (json['folder'] ?? '').toString(),
      clientName: json['clientName']?.toString(),
      deliveryAddress: json['deliveryAddress']?.toString(),
      deliveryDate: json['deliveryDate']?.toString(),
      time: json['time']?.toString(),
      returnTime: json['returnTime']?.toString(),
      note: json['note']?.toString(),
      items: itemsJson
          .whereType<Map>()
          .map(
            (e) =>
                _MonthlyEstimateItem.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }

  /// deliveryDate を日付として解釈できる場合のみ返す（"秋ごろ" 等の曖昧な表記は null）。
  DateTime? get parsedDeliveryDate {
    if (deliveryDate == null) return null;
    return DateTime.tryParse(deliveryDate!);
  }
}

/// assets/data 配下にバンドルした「Dropbox見積データ抽出」の結果(金額情報は除外済み)を
/// 1件のJSONファイルから読み込む。
Future<List<_MonthlyEstimateJob>> _loadBundledEstimateJobs(
  String assetPath,
) async {
  final raw = await rootBundle.loadString(assetPath);
  final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
  final jobsJson = (decoded['jobs'] as List?) ?? const [];
  return jobsJson
      .whereType<Map>()
      .map((e) => _MonthlyEstimateJob.fromJson(Map<String, dynamic>.from(e)))
      .toList(growable: false);
}

/// 複数の月次JSONファイルをまとめて読み込み、日付順に結合する。
/// 一部のファイルが存在しない/読み込みに失敗した場合はスキップして続行する。
Future<List<_MonthlyEstimateJob>> _loadAllBundledEstimateJobs(
  List<String> assetPaths,
) async {
  final all = <_MonthlyEstimateJob>[];
  for (final path in assetPaths) {
    try {
      all.addAll(await _loadBundledEstimateJobs(path));
    } catch (_) {
      // 該当月のファイルが未追加などの場合はスキップ
    }
  }
  all.sort((a, b) {
    final da = a.parsedDeliveryDate;
    final db = b.parsedDeliveryDate;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return da.compareTo(db);
  });
  return all;
}

/// assets/data/index.json に列挙されている月次ファイルを全て読み込む。
/// scripts/fetch_estimate_data.py を実行すると、新しい月が追加されるたびに
/// index.json が自動更新されるため、このファイルを直接編集する必要はない。
Future<List<_MonthlyEstimateJob>> _loadBundledEstimateJobsFromIndex() async {
  const indexPath = 'assets/data/index.json';
  try {
    final raw = await rootBundle.loadString(indexPath);
    final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final files = ((decoded['files'] as List?) ?? const [])
        .map((e) => 'assets/data/$e')
        .toList(growable: false);
    return _loadAllBundledEstimateJobs(files);
  } catch (_) {
    // index.jsonが無い場合は空扱い
    return const [];
  }
}

/// 「先月」〜「2か月先」の範囲(カレンダー月単位)に入るデータだけを残す。
/// 日付が解釈できない(例:「秋ごろ」)場合は非表示にせずそのまま残す。
List<_MonthlyEstimateJob> _filterJobsWithinDisplayRange(
  List<_MonthlyEstimateJob> jobs,
  DateTime now,
) {
  final rangeStart = DateTime(now.year, now.month - 1, 1);
  final rangeEndExclusive = DateTime(now.year, now.month + 3, 1);
  return jobs.where((job) {
    final d = job.parsedDeliveryDate;
    if (d == null) return true;
    return !d.isBefore(rangeStart) && d.isBefore(rangeEndExclusive);
  }).toList(growable: false);
}

/// 表示範囲のラベル(例:「2026年7月〜2026年10月」)を組み立てる。
String _buildDisplayRangeLabel(DateTime now) {
  final startMonth = DateTime(now.year, now.month - 1, 1);
  final endMonth = DateTime(now.year, now.month + 2, 1);
  final fmt = DateFormat('yyyy年M月');
  return '${fmt.format(startMonth)}〜${fmt.format(endMonth)}';
}

class _MonthlyEstimateJobTile extends StatelessWidget {
  final _MonthlyEstimateJob job;
  const _MonthlyEstimateJobTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if (job.clientName != null && job.clientName!.isNotEmpty)
        job.clientName!,
      if (job.deliveryDate != null && job.deliveryDate!.isNotEmpty)
        job.deliveryDate!,
      if (job.deliveryAddress != null && job.deliveryAddress!.isNotEmpty)
        job.deliveryAddress!,
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(
        job.folder,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: subtitleParts.isEmpty
          ? null
          : Text(
              subtitleParts.join(' / '),
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
      children: [
        if ((job.time != null && job.time!.isNotEmpty) ||
            (job.returnTime != null && job.returnTime!.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '時刻: ${job.time ?? '-'}　返却: ${job.returnTime ?? '-'}',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ),
        ...job.items.map(
          (item) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    item.memo == null || item.memo!.isEmpty
                        ? item.name
                        : '${item.name}（${item.memo}）',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                Expanded(
                  child: Text(
                    item.qtyDurationLabel,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (job.note != null && job.note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '備考: ${job.note}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
            ),
          ),
      ],
    );
  }
}

class DropboxEstimateTabScreen extends StatefulWidget {
  const DropboxEstimateTabScreen({super.key});

  @override
  State<DropboxEstimateTabScreen> createState() =>
      _DropboxEstimateTabScreenState();
}

class _DropboxEstimateTabScreenState extends State<DropboxEstimateTabScreen>
    with AutomaticKeepAliveClientMixin {
  // 表示する月次データは assets/data/index.json から自動的に読み込まれる。
  // scripts/fetch_estimate_data.py を実行すると、Dropboxの「機材レンタル」フォルダ
  // から新しい月の見積データ抽出ファイルが取得され、index.json が自動更新される。
  late Future<List<_MonthlyEstimateJob>> _localJobsFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _localJobsFuture = _loadBundledEstimateJobsFromIndex();
  }

  Future<void> _reload() async {
    setState(() {
      _localJobsFuture = _loadBundledEstimateJobsFromIndex();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('見積抽出'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<List<_MonthlyEstimateJob>>(
        future: _localJobsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('読み込みに失敗しました\n${snapshot.error}'),
              ),
            );
          }
          final allJobs = snapshot.data ?? const <_MonthlyEstimateJob>[];
          final jobs = _filterJobsWithinDisplayRange(allJobs, now);
          if (jobs.isEmpty) {
            return const Center(child: Text('登録済みの見積データがありません'));
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_buildDisplayRangeLabel(now)} 登録済み見積データ'
                    '（金額非表示・${jobs.length}件）',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: jobs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFEEEEEE)),
                      ),
                      child: _MonthlyEstimateJobTile(job: jobs[index]),
                    );
                  },
                ),
              ),
            ],
          );
        },
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
        backgroundColor: Colors.white,
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
                      color: Color(0xFF1976D2),
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
                            backgroundColor: Colors.grey[100],
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
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: '会場名・部屋名で検索...',
                      prefixIcon: Icon(Icons.search),
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => _onSearchChanged(),
                  ),
                ),
              ),
              SizedBox(
                height: 45,
                child: ListView(
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
                                        color: Colors.orange,
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
            ],
          ),
        ),
      ),
      body: StreamBuilder<List<_SearchResultDocument>>(
        stream: venueStream,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            _lastVenueDocs = snapshot.data!;
          }
          final searchDocs = snapshot.data ?? _lastVenueDocs;
          if (searchDocs.isEmpty && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
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
          return RefreshIndicator(
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
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEEEEEE)),
                  ),
                  child: ListTile(
                    title: Row(
                      children: [
                        if (hasAttention) ...[
                          const Tooltip(
                            message: '要注意項目あり',
                            child: Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.redAccent,
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
                            style: const TextStyle(fontWeight: FontWeight.bold),
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
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text('エラー: $e')),
                                        );
                                      }
                                    }
                                  },
                                )
                              : const Icon(Icons.location_on),
                        ],
                      ),
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
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFEEEEEE)),
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
          border: Border.all(color: const Color(0xFFEEEEEE)),
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
                        _selectedSourceFilter = _selectedSourceFilter == filter
                            ? null
                            : filter;
                      }),
                    ),
                  ),
                ),
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
                        'データの読み込みに失敗しました\n${snapshot.error}',
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
                    Center(child: Text('表示できるデータがありません')),
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
                                            color: isToday
                                                ? const Color(0xFFE3F2FD)
                                                : isTomorrow
                                                ? const Color(0xFFFFF59D)
                                                : const Color(0xFFF3F3F3),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: isToday
                                                  ? const Color(0xFF64B5F6)
                                                  : isTomorrow
                                                  ? const Color(0xFFFFE082)
                                                  : const Color(0xFFDADADA),
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
                    );
                  }

                  return Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    decoration: BoxDecoration(
                      color: isToday
                          ? const Color(0xFFE3F2FD)
                          : isTomorrow
                          ? const Color(0xFFFFF59D)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isToday
                            ? const Color(0xFF64B5F6)
                            : isTomorrow
                            ? const Color(0xFFFFE082)
                            : const Color(0xFFEEEEEE),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // シフト(左) + ZAIKI(右)を横並び。
                        // ZAIKI側はカードを縦に積み、シフトが長い場合は縦スクロール。
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

            final weekRows = snapshot.data ?? const <_WeeklySourceDayData>[];
            if (weekRows.isEmpty) {
              return RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 220),
                    Center(child: Text('1か月分の抽出データは見つかりませんでした')),
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

                  return Container(
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
                              color: isTodayGroup
                                  ? const Color(0xFFBBDEFB)
                                  : isTomorrowGroup
                                  ? const Color(0xFFFFF176)
                                  : const Color(0xFFF8F8F8),
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
                                            color: const Color(0xFFEEEEEE),
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
        color: const Color.fromARGB(255, 255, 102, 0),
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
      appBar: AppBar(
        title: const Text('予約履歴'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(66),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              height: 50,
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '顧客・会場名で検索...',
                  prefixIcon: Icon(Icons.search),
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (_) => _onSearchChanged(),
              ),
            ),
          ),
        ),
      ),
      body: StreamBuilder<List<_SearchResultDocument>>(
        stream: bookingStream,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            _lastBookingDocs = snapshot.data!;
          }
          final searchDocs = snapshot.data ?? _lastBookingDocs;
          if (searchDocs.isEmpty && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.center,
                  child: OutlinedButton.icon(
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
                child: RefreshIndicator(
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

                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEEEEEE)),
                        ),
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
                                    color: Colors.grey[100],
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
                                ? (isCompactMobile ? 164 : 180)
                                : (isCompactMobile ? 82 : 100),
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
                              ],
                            ),
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
        backgroundColor: const Color.fromARGB(255, 255, 102, 0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.post_add),
        label: const Text('予約を登録'),
      ),
    );
  }
}

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

// --- 予約詳細シート ---
class BookingDetailSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final String docId;
  const BookingDetailSheet({
    super.key,
    required this.data,
    required this.docId,
  });

  @override
  State<BookingDetailSheet> createState() => _BookingDetailSheetState();
}

class _BookingDetailSheetState extends State<BookingDetailSheet> {
  late Map<String, dynamic> _currentData = Map<String, dynamic>.from(
    widget.data,
  );
  bool _isEditingPhoto = false;

  void _showImageGallery(BuildContext context, List urls, int startIndex) {
    final controller = PageController(initialPage: startIndex);
    showDialog(
      context: context,
      builder: (ctx) {
        var currentIndex = startIndex;
        final transformController = TransformationController();
        Offset? doubleTapPos;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> goPrev() {
              return controller.previousPage(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
              );
            }

            Future<void> goNext() {
              return controller.nextPage(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
              );
            }

            Future<void> openEditorForCurrentImage() async {
              if (_isEditingPhoto ||
                  currentIndex < 0 ||
                  currentIndex >= urls.length) {
                return;
              }
              final imageUrl = urls[currentIndex].toString();
              Navigator.of(ctx).pop();
              await _editBookingPhotoWithPen(
                imageUrl: imageUrl,
                imageIndex: currentIndex,
              );
            }

            return Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }

                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  Navigator.of(ctx).pop();
                  return KeyEventResult.handled;
                }

                if (urls.length <= 1) {
                  return KeyEventResult.ignored;
                }

                if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
                    currentIndex > 0) {
                  goPrev();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
                    currentIndex < urls.length - 1) {
                  goNext();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Dialog(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                insetPadding: const EdgeInsets.all(16),
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.9,
                    maxHeight: MediaQuery.of(context).size.height * 0.9,
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: ClipRect(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    44,
                                    12,
                                    12,
                                  ),
                                  child: PageView.builder(
                                    controller: controller,
                                    itemCount: urls.length,
                                    onPageChanged: (index) {
                                      setDialogState(
                                        () => currentIndex = index,
                                      );
                                      transformController.value =
                                          Matrix4.identity();
                                    },
                                    itemBuilder: (context, i) => LayoutBuilder(
                                      builder: (context, constraints) =>
                                          GestureDetector(
                                            onDoubleTapDown: (details) {
                                              doubleTapPos =
                                                  details.localPosition;
                                            },
                                            onDoubleTap: () {
                                              final isZoomed =
                                                  transformController.value
                                                      .getMaxScaleOnAxis() >
                                                  1.05;
                                              if (isZoomed) {
                                                transformController.value =
                                                    Matrix4.identity();
                                              } else {
                                                final pos =
                                                    doubleTapPos ??
                                                    Offset(
                                                      constraints.maxWidth / 2,
                                                      constraints.maxHeight / 2,
                                                    );
                                                const scale = 2.5;
                                                transformController.value =
                                                    Matrix4.identity()
                                                      ..translateByDouble(
                                                        -pos.dx * (scale - 1),
                                                        -pos.dy * (scale - 1),
                                                        0,
                                                        1,
                                                      )
                                                      ..scaleByDouble(
                                                        scale,
                                                        scale,
                                                        1,
                                                        1,
                                                      );
                                              }
                                            },
                                            child: InteractiveViewer(
                                              transformationController:
                                                  transformController,
                                              clipBehavior: Clip.hardEdge,
                                              child: SizedBox(
                                                width: constraints.maxWidth,
                                                height: constraints.maxHeight,
                                                child: Image.network(
                                                  urls[i],
                                                  fit: BoxFit.contain,
                                                ),
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 12,
                                bottom: 12,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Material(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(999),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        onTap: _isEditingPhoto
                                            ? null
                                            : openEditorForCurrentImage,
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: _isEditingPhoto
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    valueColor:
                                                        AlwaysStoppedAnimation<
                                                          Color
                                                        >(Colors.white),
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.brush,
                                                  size: 18,
                                                  color: Colors.white,
                                                ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Material(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(999),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        onTap: () => Navigator.of(ctx).pop(),
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Icon(
                                            Icons.close,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (urls.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton.filledTonal(
                                onPressed: currentIndex > 0 ? goPrev : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              const SizedBox(width: 12),
                              Text('${currentIndex + 1} / ${urls.length}'),
                              const SizedBox(width: 12),
                              IconButton.filledTonal(
                                onPressed: currentIndex < urls.length - 1
                                    ? goNext
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _reloadBooking() async {
    final snap = await FirebaseFirestore.instance
        .collection('bookings')
        .doc(widget.docId)
        .get();
    if (!mounted || !snap.exists) return;
    setState(() {
      _currentData = snap.data() ?? <String, dynamic>{};
    });
  }

  Future<void> _editBookingPhotoWithPen({
    required String imageUrl,
    required int imageIndex,
  }) async {
    if (_isEditingPhoto) return;

    setState(() => _isEditingPhoto = true);
    try {
      final response = await http.get(Uri.parse(imageUrl));
      if (response.statusCode != 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('画像の読み込みに失敗しました')));
        return;
      }

      if (!mounted) return;
      final editedBytes = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoAnnotationPage(imageBytes: response.bodyBytes),
        ),
      );

      if (editedBytes == null) return;

      var uploadBytes = editedBytes;
      final decodedImage = img.decodeImage(editedBytes);
      if (decodedImage != null) {
        uploadBytes = Uint8List.fromList(
          img.encodeJpg(decodedImage, quality: 90),
        );
      }

      final storageRef = FirebaseStorage.instance.ref().child(
        'bookings/${DateTime.now().millisecondsSinceEpoch}_$imageIndex.jpg',
      );
      await storageRef
          .putData(uploadBytes, SettableMetadata(contentType: 'image/jpeg'))
          .timeout(_bookingStorageUploadTimeout);
      final editedUrl = await storageRef.getDownloadURL().timeout(
        _bookingStorageUploadTimeout,
      );

      final currentUrls = List<String>.from(
        _currentData['imageUrls'] ?? const [],
      );
      if (imageIndex < 0 || imageIndex >= currentUrls.length) {
        await _reloadBooking();
        return;
      }

      currentUrls[imageIndex] = editedUrl;
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.docId)
          .update({
            'imageUrls': currentUrls,
            'updatedAt': FieldValue.serverTimestamp(),
          });
      _invalidateSearchQueryCache(namespace: 'bookings');

      if (!mounted) return;
      setState(() {
        _currentData['imageUrls'] = currentUrls;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('写真を更新しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写真編集の保存に失敗しました: $e')));
    } finally {
      if (mounted) {
        setState(() => _isEditingPhoto = false);
      }
    }
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

  Future<void> _openVenueDetail(BuildContext context) async {
    final venueId = (_currentData['venueId'] ?? '').toString().trim();
    if (venueId.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('venues')
          .doc(venueId)
          .get();
      if (!snap.exists) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('会場情報が見つかりませんでした')));
        }
        return;
      }
      if (context.mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (_) => VenueDetailSheet(data: snap.data()!, docId: snap.id),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('会場情報の取得に失敗しました: $e')));
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
          .doc(widget.docId)
          .delete();
      _invalidateSearchQueryCache(namespace: 'bookings');
      if (context.mounted) Navigator.pop(context);
    }
  }

  Widget _buildRetrospectiveBox(String title, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFDADADA)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 6),
          _buildPreservedCardText(
            value,
            style: const TextStyle(fontSize: 16, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _buildLabeledBox(String title, String value, {Color? textColor}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFDADADA)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 6),
          _buildPreservedCardText(
            value,
            style: TextStyle(fontSize: 16, height: 1.6, color: textColor),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _currentData;
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
              child: SelectionArea(
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
                              onPressed: () async {
                                final updated = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => AddBookingScreen(
                                      docId: widget.docId,
                                      initialData: data,
                                    ),
                                  ),
                                );
                                if (updated != false) {
                                  await _reloadBooking();
                                }
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
                    _detailRow(
                      Icons.calendar_today,
                      '利用日',
                      data['bookingDate'],
                    ),
                    Builder(
                      builder: (context) {
                        final hasVenueId = (data['venueId'] ?? '')
                            .toString()
                            .trim()
                            .isNotEmpty;
                        return InkWell(
                          onTap: hasVenueId
                              ? () => _openVenueDetail(context)
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            children: [
                              _detailRow(
                                Icons.location_on_outlined,
                                '会場 ${hasVenueId ? '(タップで詳細)' : ''}',
                                data['venueName'],
                              ),
                              if (hasVenueId)
                                const Positioned(
                                  right: 0,
                                  top: 8,
                                  child: Icon(
                                    Icons.chevron_right,
                                    color: Colors.grey,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
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
                    if (urls.isNotEmpty)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        clipBehavior: Clip.hardEdge,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: 1,
                            ),
                        itemCount: urls.length,
                        itemBuilder: (context, i) => GestureDetector(
                          onTap: () => _showImageGallery(context, urls, i),
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox.expand(
                                child: Image.network(
                                  urls[i],
                                  fit: BoxFit.cover,
                                  cacheWidth: 640,
                                  cacheHeight: 640,
                                  filterQuality: FilterQuality.medium,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (urls.isEmpty && pdfUrls.isEmpty) const Text('なし'),
                    if (pdfUrls.isNotEmpty) ...[
                      if (urls.isNotEmpty) const SizedBox(height: 10),
                      ...pdfUrls.map(
                        (url) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _launchURL(context, url.toString()),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFFDADADA),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.picture_as_pdf,
                                    color: Colors.red,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'PDFを開く',
                                      style: TextStyle(
                                        color: Colors.grey[800],
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.open_in_new,
                                    size: 18,
                                    color: Colors.grey,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    const SizedBox(height: 24),
                    _buildLabeledBox(
                      '備考',
                      (data['remarks'] ?? 'なし').toString(),
                    ),
                    const SizedBox(height: 24),
                    _buildLabeledBox(
                      '引継ぎ事項',
                      (data['handover'] ?? 'なし').toString(),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '振り返り',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildRetrospectiveBox(
                      '成果',
                      (data['retrospectiveResult'] ?? '').toString(),
                    ),
                    const SizedBox(height: 10),
                    _buildRetrospectiveBox(
                      '課題',
                      (data['retrospectiveIssue'] ?? '').toString(),
                    ),
                    const SizedBox(height: 10),
                    _buildRetrospectiveBox(
                      '解決策',
                      (data['retrospectiveSolution'] ?? '').toString(),
                    ),
                    const SizedBox(height: 10),
                    _buildRetrospectiveBox(
                      '次回へ',
                      (data['retrospectiveNext'] ?? '').toString(),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- 会場詳細シート ---
class VenueDetailSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final String docId;
  const VenueDetailSheet({super.key, required this.data, required this.docId});

  @override
  State<VenueDetailSheet> createState() => _VenueDetailSheetState();
}

class _VenueDetailSheetState extends State<VenueDetailSheet> {
  late Map<String, dynamic> _currentData = Map<String, dynamic>.from(
    widget.data,
  );

  Future<void> _launchVenueUrl(BuildContext context, String url) async {
    final raw = url.trim();
    if (raw.isEmpty) return;

    final uri = Uri.parse(raw.startsWith('http') ? raw : 'https://$raw');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('リンクを開けませんでした')));
    }
  }

  Future<void> _reloadVenue() async {
    final snap = await FirebaseFirestore.instance
        .collection('venues')
        .doc(widget.docId)
        .get();
    if (!mounted || !snap.exists) return;
    setState(() {
      _currentData = snap.data() ?? <String, dynamic>{};
    });
  }

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
      await FirebaseFirestore.instance
          .collection('venues')
          .doc(widget.docId)
          .delete();
      _invalidateSearchQueryCache(namespace: 'venues');
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _currentData;
    final attentionItems = _extractVenueAttentionItems(data);
    final extraChargeNote = _extractVenueExtraChargeNote(data);
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
              child: SelectionArea(
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
                              onPressed: () async {
                                final updated = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => AddVenueScreen(
                                      docId: widget.docId,
                                      initialData: data,
                                    ),
                                  ),
                                );
                                if (updated != false) {
                                  await _reloadVenue();
                                }
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
                    if ((data['url'] ?? '').toString().trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: InkWell(
                          onTap: () => _launchVenueUrl(context, data['url']),
                          child: _detailRow(
                            Icons.link,
                            'URLリンク (タップで開く)',
                            data['url'],
                          ),
                        ),
                      ),
                    _detailRow(
                      Icons.warning_amber,
                      '要注意項目',
                      attentionItems.isEmpty
                          ? null
                          : attentionItems.join(' / '),
                    ),
                    _detailRow(
                      Icons.currency_yen_rounded,
                      '追加料金発生',
                      extraChargeNote.isEmpty ? null : extraChargeNote,
                    ),
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
                            .where('venueId', isEqualTo: widget.docId)
                            .snapshots(),
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return Center(
                              child: Text('履歴の取得に失敗しました: ${snap.error}'),
                            );
                          }
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
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
                          if (docs.isEmpty) {
                            return const Center(child: Text('履歴がありません'));
                          }
                          return ListView.separated(
                            itemCount: docs.length,
                            padding: EdgeInsets.zero,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final b = docs[i].data() as Map<String, dynamic>;
                              final List urls = b['imageUrls'] ?? [];
                              final bookingTags = _extractBookingTagsFromData(
                                b,
                              );
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
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: Image.network(
                                            urls[0],
                                            width: 50,
                                            height: 50,
                                            fit: BoxFit.cover,
                                            cacheWidth: 120,
                                            cacheHeight: 120,
                                            filterQuality: FilterQuality.medium,
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
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          b['customerName'] ?? '',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (bookingTags.isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Wrap(
                                          spacing: 4,
                                          runSpacing: 4,
                                          children: bookingTags
                                              .map(_buildBookingTagChip)
                                              .toList(growable: false),
                                        ),
                                      ],
                                    ],
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
    'power': TextEditingController(),
    'capacity': TextEditingController(),
    'url': TextEditingController(),
    'extraChargeNote': TextEditingController(),
    'remarks': TextEditingController(),
  };
  final Set<String> _selectedAttentionItems = <String>{};
  String? _selectedBlock, _selectedCategory;
  bool _isSaving = false;
  Timer? _autoSaveDebounce;
  String? _lastSavedDraftSignature;
  _VenueAreaData? _areaData; // エリアデータをキャッシュ
  final TextEditingController _areaController = TextEditingController();

  bool get _isEditMode => widget.docId != null;

  Map<String, dynamic> _buildVenueDraftData() {
    final attentionItems = _selectedAttentionItems.toList()..sort();
    return {
      for (var e in _controllers.entries) e.key: e.value.text.trim(),
      'block': _selectedBlock,
      'category': _selectedCategory,
      'attentionItems': attentionItems,
      'attentionNote': attentionItems.join(' / '),
    };
  }

  String _buildVenueDraftSignature() => jsonEncode(_buildVenueDraftData());

  void _onVenueInputChanged() {
    if (!_isEditMode) return;
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    if (!_isEditMode) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      unawaited(_saveVenue(closeOnSuccess: false, showValidationError: false));
    });
  }

  Widget _buildAreaSelector() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _areaController,
            decoration: const InputDecoration(labelText: 'エリア'),
            minLines: 1,
            maxLines: 1,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            onChanged: (value) {
              setState(
                () =>
                    _selectedBlock = value.trim().isEmpty ? null : value.trim(),
              );
              _scheduleAutoSave();
            },
          ),
        ),
        const SizedBox(width: 8),
        if (_selectedBlock != null && _selectedBlock!.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.orange),
            tooltip: 'エリアの詳細を表示',
            onPressed: () {
              final selectedArea = _selectedBlock!.trim();
              if (!_venueAreaSectionOrder.contains(selectedArea)) {
                _showSnackBar('エリア1〜エリア5を入力してください');
                return;
              }
              _showAreaDialog(selectedArea);
            },
          ),
      ],
    );
  }

  Future<void> _showAreaDialog(String selectedArea) async {
    if (_areaData == null) {
      _showSnackBar('エリアデータが読み込まれていません');
      return;
    }

    final prefectures = _areaData!.areaTables[selectedArea] ?? const {};
    if (prefectures.isEmpty) {
      _showSnackBar('このエリアのデータがありません');
      return;
    }

    final prefectureEntries = prefectures.entries.toList(growable: false);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
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
                      color: Color(0xFF1976D2),
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
                            backgroundColor: Colors.grey[100],
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

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      widget.initialData!.forEach((key, val) {
        if (_controllers.containsKey(key)) {
          _controllers[key]?.text = val?.toString() ?? '';
        }
      });
      _selectedBlock = widget.initialData!['block'];
      _areaController.text = (_selectedBlock ?? '').toString();
      _selectedCategory = widget.initialData!['category'];
      _selectedAttentionItems
        ..clear()
        ..addAll(_extractVenueAttentionItems(widget.initialData!));
      // 位置情報の初期化削除
    }

    for (final controller in _controllers.values) {
      controller.addListener(_onVenueInputChanged);
    }

    _lastSavedDraftSignature = _buildVenueDraftSignature();

    // 住所フィールドで自動エリア判定を設定
    _controllers['address']?.addListener(_onAddressChanged);

    // 市区町村->エリアのマッピングを初期化
    _fetchVenueAreaData()
        .then((data) {
          _areaData = data; // エリアデータをキャッシュ
          _initializeCityAreaMapping(data);
          // データ読み込み完了後、現在の住所から自動判定を試す
          _onAddressChanged();
        })
        .catchError((e) {
          /* エラーは無視 */
        });
  }

  void _onAddressChanged() {
    final address = _controllers['address']?.text ?? '';
    if (address.isEmpty) return;
    if (_prefectureCityAreaMapping.isEmpty && _cityAreaMapping.isEmpty) return;

    final detectedArea = _detectAreaFromAddress(address);
    if (detectedArea != null && detectedArea != _selectedBlock) {
      setState(() {
        _selectedBlock = detectedArea;
        _areaController.text = detectedArea;
      });
      _scheduleAutoSave();
    }
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _controllers['address']?.removeListener(_onAddressChanged);
    for (final controller in _controllers.values) {
      controller.removeListener(_onVenueInputChanged);
    }
    _controllers.forEach((_, controller) => controller.dispose());
    _areaController.dispose();
    super.dispose();
  }

  Future<void> _saveVenue({
    bool closeOnSuccess = true,
    bool showValidationError = true,
  }) async {
    if (_isSaving) return;

    final name = _controllers['name']?.text.trim() ?? '';
    if (name.isEmpty) {
      if (showValidationError) {
        _showSnackBar('建物名を入力してください');
      }
      return;
    }

    final draftSignature = _buildVenueDraftSignature();
    if (_isEditMode && draftSignature == _lastSavedDraftSignature) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final draft = _buildVenueDraftData();
      final data = {
        ...draft,
        ..._buildVenueSearchIndex(
          name,
          shopAndRoom: _controllers['shopAndRoom']?.text.trim(),
        ),
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

      _lastSavedDraftSignature = draftSignature;

      _invalidateSearchQueryCache(namespace: 'venues');

      if (!mounted) return;
      if (closeOnSuccess) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showSnackBar('会場情報の保存に失敗しました: $e');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
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
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _addNewItem(col, label);
                }
              });
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
      barrierDismissible: false,
      builder: (ctx) {
        var isSubmitting = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: Text('$labelの追加'),
            content: TextField(
              controller: c,
              enabled: !isSubmitting,
              autofocus: true,
              decoration: const InputDecoration(hintText: '名前を入力'),
              onSubmitted: (_) async {
                if (isSubmitting) return;
                final value = c.text.trim();
                if (value.isEmpty) return;
                setDialogState(() => isSubmitting = true);
                try {
                  await FirebaseFirestore.instance
                      .collection(col)
                      .add({'name': value})
                      .timeout(const Duration(seconds: 10));
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                } catch (e) {
                  if (dialogContext.mounted) {
                    setDialogState(() => isSubmitting = false);
                  }
                  _showSnackBar('$labelの追加に失敗しました: $e');
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final value = c.text.trim();
                        if (value.isEmpty) return;
                        setDialogState(() => isSubmitting = true);
                        try {
                          await FirebaseFirestore.instance
                              .collection(col)
                              .add({'name': value})
                              .timeout(const Duration(seconds: 10));
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            setDialogState(() => isSubmitting = false);
                          }
                          _showSnackBar('$labelの追加に失敗しました: $e');
                        }
                      },
                child: isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('追加'),
              ),
            ],
          ),
        );
      },
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
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }
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

  Widget _buildAttentionChecklist() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('attentionItems')
          .orderBy('name')
          .snapshots(),
      builder: (context, snap) {
        final items =
            snap.data?.docs.map((d) => d['name'] as String).toList() ?? [];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '要注意項目',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.grey),
                  tooltip: '要注意項目を管理',
                  onPressed: () => _manageItems('attentionItems', '要注意項目'),
                ),
              ],
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('項目がありません。設定から追加してください。'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: items.map((item) {
                    final checked = _selectedAttentionItems.contains(item);
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setState(() {
                          if (checked) {
                            _selectedAttentionItems.remove(item);
                          } else {
                            _selectedAttentionItems.add(item);
                          }
                        });
                        _scheduleAutoSave();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: checked,
                              visualDensity: VisualDensity.compact,
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedAttentionItems.add(item);
                                  } else {
                                    _selectedAttentionItems.remove(item);
                                  }
                                });
                                _scheduleAutoSave();
                              },
                            ),
                            Text(item),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
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
    final leadingSlotWidth = _isEditMode ? 160.0 : 56.0;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: leadingSlotWidth,
        centerTitle: true,
        titleSpacing: 0,
        leading: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            const BackButton(),
            if (_isEditMode)
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isSaving ? Icons.sync : Icons.check_circle_outline,
                          size: 20,
                          color: _isSaving ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isSaving ? '自動保存中...' : '自動保存',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _isSaving ? Colors.orange : Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        title: Text(widget.docId == null ? '会場の登録' : '会場の編集'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _controllers['name'],
              decoration: const InputDecoration(labelText: '建物名'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['shopAndRoom'],
              decoration: const InputDecoration(labelText: '部屋/店名'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            _buildAreaSelector(),
            const SizedBox(height: 15),
            _buildDropdown('カテゴリ', 'categories', _selectedCategory, (v) {
              setState(() => _selectedCategory = v);
              _scheduleAutoSave();
            }),
            const SizedBox(height: 15),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controllers['address'],
                    decoration: const InputDecoration(labelText: '住所'),
                    minLines: 1,
                    maxLines: 1,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.next,
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
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['parking'],
              decoration: const InputDecoration(labelText: '駐車場'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['power'],
              decoration: const InputDecoration(labelText: '電源'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['capacity'],
              decoration: const InputDecoration(labelText: 'キャパ'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['url'],
              decoration: const InputDecoration(labelText: 'URLリンク'),
              minLines: 1,
              maxLines: 1,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            _buildAttentionChecklist(),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['extraChargeNote'],
              decoration: const InputDecoration(labelText: '追加料金発生'),
              minLines: 2,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _controllers['remarks'],
              decoration: const InputDecoration(labelText: '備考'),
              minLines: 3,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
            const SizedBox(height: 40),
            if (!_isEditMode)
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

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// --- クラスの外に配置 ---
// compute用: 重い画像処理をバックグラウンドで行う
const int _bookingImageMaxDimension = 1600;
const int _bookingImageFallbackDimension = 1024;
const int _bookingImageTargetBytes = 220 * 1024;
const Duration _bookingStorageUploadTimeout = Duration(minutes: 2);

Future<Uint8List> _processImageIsolate(Map<String, dynamic> params) async {
  final Uint8List bytes = params['bytes'];
  img.Image? image = img.decodeImage(bytes);
  if (image == null) return bytes;

  // 長辺だけを基準に縮小して、縦長画像の不要な拡大を避ける。
  if (image.width > _bookingImageMaxDimension ||
      image.height > _bookingImageMaxDimension) {
    image = image.width >= image.height
        ? img.copyResize(image, width: _bookingImageMaxDimension)
        : img.copyResize(image, height: _bookingImageMaxDimension);
  }

  var result = Uint8List.fromList(img.encodeJpg(image, quality: 80));

  if (result.lengthInBytes > _bookingImageTargetBytes) {
    result = Uint8List.fromList(img.encodeJpg(image, quality: 68));
  }

  if (result.lengthInBytes > _bookingImageTargetBytes &&
      (image.width > _bookingImageFallbackDimension ||
          image.height > _bookingImageFallbackDimension)) {
    final resized = image.width >= image.height
        ? img.copyResize(image, width: _bookingImageFallbackDimension)
        : img.copyResize(image, height: _bookingImageFallbackDimension);
    result = Uint8List.fromList(img.encodeJpg(resized, quality: 60));
    if (result.lengthInBytes > _bookingImageTargetBytes) {
      result = Uint8List.fromList(img.encodeJpg(resized, quality: 52));
    }
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
  final _resultController = TextEditingController();
  final _issueController = TextEditingController();
  final _solutionController = TextEditingController();
  final _nextController = TextEditingController();
  final _venueSearchController = TextEditingController();

  // --- State Variables ---
  String? _selectedVenueId, _selectedVenueName;
  final List<_PendingImage> _newImages = []; // 新しく選択された画像
  List<String> _existingUrls = []; // すでにFirestoreにある画像
  List<String> _existingPdfUrls = []; // すでにFirestoreにあるPDF
  List<String> _existingPdfNames = []; // すでにFirestoreにあるPDF名
  bool _isUploading = false;
  bool _showVenueList = false;
  String _venueSearchQuery = '';
  bool _isTra = false;
  bool _isOpe = false;
  List<_SearchResultDocument> _lastVenuePickerDocs = const [];
  Timer? _autoSaveDebounce;
  String? _lastSavedDraftSignature;

  bool get _isEditMode => widget.docId != null;

  List<TextEditingController> get _autoSaveControllers => [
    _customerController,
    _staffController,
    _dateController,
    _remarksController,
    _handoverController,
    _resultController,
    _issueController,
    _solutionController,
    _nextController,
  ];

  Map<String, dynamic> _buildBookingDraftData() {
    final customerTags = <String>[if (_isTra) 'トラ', if (_isOpe) 'オペ'];
    return {
      'customerName': _customerController.text.trim(),
      'staffName': _staffController.text.trim(),
      'bookingDate': _dateController.text.trim(),
      'remarks': _remarksController.text.trim(),
      'handover': _handoverController.text.trim(),
      'retrospectiveResult': _resultController.text.trim(),
      'retrospectiveIssue': _issueController.text.trim(),
      'retrospectiveSolution': _solutionController.text.trim(),
      'retrospectiveNext': _nextController.text.trim(),
      'venueId': _selectedVenueId,
      'venueName': (_selectedVenueName ?? _venueSearchController.text).trim(),
      'customerTags': customerTags,
      'imageUrls': _existingUrls,
      'pdfUrls': _existingPdfUrls,
      'pdfFileNames': _existingPdfNames,
      'pendingImageCount': _newImages.length,
      'pendingImageBytes': _newImages.fold<int>(
        0,
        (totalBytes, image) => totalBytes + image.bytes.length,
      ),
    };
  }

  String _buildBookingDraftSignature() => jsonEncode(_buildBookingDraftData());

  void _onBookingInputChanged() {
    if (!_isEditMode) return;
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    if (!_isEditMode) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      unawaited(_save(closeOnSuccess: false, showValidationError: false));
    });
  }

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
      _resultController.text = d['retrospectiveResult'] ?? '';
      _issueController.text = d['retrospectiveIssue'] ?? '';
      _solutionController.text = d['retrospectiveSolution'] ?? '';
      _nextController.text = d['retrospectiveNext'] ?? '';
      final customerTags =
          (d['customerTags'] as List?)?.map((e) => e.toString()).toSet() ??
          const <String>{};
      _isTra = d['isTra'] == true || customerTags.contains('トラ');
      _isOpe = d['isOpe'] == true || customerTags.contains('オペ');
      _selectedVenueId = d['venueId'];
      _selectedVenueName = d['venueName'];
      _venueSearchController.text = d['venueName'] ?? '';
      _venueSearchQuery = _venueSearchController.text;
      _existingUrls = List<String>.from(d['imageUrls'] ?? []);
      _existingPdfUrls = List<String>.from(d['pdfUrls'] ?? []);
      _existingPdfNames = List<String>.from(d['pdfFileNames'] ?? []);
    } else {
      _venueSearchQuery = _venueSearchController.text;
    }

    for (final controller in _autoSaveControllers) {
      controller.addListener(_onBookingInputChanged);
    }
    _lastSavedDraftSignature = _buildBookingDraftSignature();
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    for (final controller in _autoSaveControllers) {
      controller.removeListener(_onBookingInputChanged);
    }
    _customerController.dispose();
    _staffController.dispose();
    _dateController.dispose();
    _remarksController.dispose();
    _handoverController.dispose();
    _resultController.dispose();
    _issueController.dispose();
    _solutionController.dispose();
    _nextController.dispose();
    _venueSearchController.dispose();
    super.dispose();
  }

  void _scheduleVenueSearchUpdate(String value) {
    if (_venueSearchQuery == value) return;
    setState(() => _venueSearchQuery = value);
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
        'attentionItems': <String>[],
        'attentionNote': '',
        'extraChargeItems': <String>[],
        'extraChargeNote': '',
        'remarks': '',
        'block': null,
        'category': null,
        'power': '',
        ..._buildVenueSearchIndex(name),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      _invalidateSearchQueryCache(namespace: 'venues');
      setState(() {
        _selectedVenueId = docRef.id;
        _selectedVenueName = name;
        _venueSearchQuery = name;
        _showVenueList = false;
      });
      _scheduleAutoSave();
      _showSnackBar('新規会場として登録しました');
    } catch (e) {
      _showSnackBar('会場登録に失敗しました: $e');
    } finally {
      setState(() => _isUploading = false);
    }
  }

  Future<void> _openAnnotationFromUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        _showSnackBar('画像の読み込みに失敗しました');
        return;
      }
      if (!mounted) return;
      final result = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoAnnotationPage(imageBytes: response.bodyBytes),
        ),
      );
      if (result != null && mounted) {
        setState(() {
          _existingUrls.remove(url);
          _newImages.add(_PendingImage(bytes: result));
        });
        _scheduleAutoSave();
      }
    } catch (e) {
      _showSnackBar('画像の読み込みに失敗しました');
    }
  }

  Future<void> _openAnnotationFromPendingImage(_PendingImage image) async {
    final result = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoAnnotationPage(imageBytes: image.bytes),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        final index = _newImages.indexOf(image);
        if (index >= 0) _newImages[index] = _PendingImage(bytes: result);
      });
      _scheduleAutoSave();
    }
  }

  Future<void> _openPdfWithExternalApp(String pdfUrl) async {
    try {
      final uri = Uri.parse(pdfUrl);
      if (!await canLaunchUrl(uri)) {
        _showSnackBar('PDFを開けませんでした');
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _showSnackBar('PDFを開けませんでした');
    }
  }

  Future<void> _createPdfMemoWithPen(String title) async {
    final memoImage = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoAnnotationPage.blank(title: 'PDFメモ: $title'),
      ),
    );

    if (memoImage == null || !mounted) return;
    setState(() {
      _newImages.add(_PendingImage(bytes: memoImage));
    });
    _scheduleAutoSave();
  }

  // --- Logic: Image Management ---

  Future<void> _pickImages() async {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: _bookingImageMaxDimension.toDouble(),
      maxHeight: _bookingImageMaxDimension.toDouble(),
      imageQuality: 70,
    );
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
    _scheduleAutoSave();
  }

  // --- Logic: Save ---

  Future<void> _save({
    bool closeOnSuccess = true,
    bool showValidationError = true,
  }) async {
    if (_isUploading) return;

    if (_selectedVenueId == null || _customerController.text.trim().isEmpty) {
      if (showValidationError) {
        _showSnackBar('会場と顧客名を入力してください');
      }
      return;
    }

    final draftSignature = _buildBookingDraftSignature();
    if (_isEditMode && draftSignature == _lastSavedDraftSignature) {
      return;
    }

    setState(() {
      _isUploading = true;
    });

    // 手動保存時のみ確実にローディング表示を出す。
    if (showValidationError) {
      await Future.delayed(const Duration(milliseconds: 50));
    }

    try {
      final List<String> newUrls = await _uploadImages();
      await _saveToFirestore(newUrls);

      if (newUrls.isNotEmpty && mounted) {
        setState(() {
          _existingUrls = [..._existingUrls, ...newUrls];
          _newImages.clear();
        });
      }

      _lastSavedDraftSignature = _buildBookingDraftSignature();

      if (mounted && closeOnSuccess) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('Error during save: $e');
      _showSnackBar('保存失敗: $e');
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  Future<List<String>> _uploadImages() async {
    if (_newImages.isEmpty) return [];

    final storage = FirebaseStorage.instance;
    final List<String> uploadedUrls = [];

    for (final image in _newImages) {
      final originalBytes = image.bytes;
      final uploadBytes =
          kIsWeb || originalBytes.lengthInBytes <= _bookingImageTargetBytes
          ? originalBytes
          : await compute(_processImageIsolate, {'bytes': originalBytes});
      final fileName =
          'bookings/${DateTime.now().millisecondsSinceEpoch}_${uploadedUrls.length}.jpg';

      final ref = storage.ref().child(fileName);
      await ref
          .putData(uploadBytes, SettableMetadata(contentType: 'image/jpeg'))
          .timeout(_bookingStorageUploadTimeout);
      final downloadUrl = await ref.getDownloadURL().timeout(
        _bookingStorageUploadTimeout,
      );
      uploadedUrls.add(downloadUrl);
    }

    return uploadedUrls;
  }

  Future<void> _saveToFirestore(List<String> newUrls) async {
    final venueNameFromInput = _venueSearchController.text.trim();
    var venueName = (_selectedVenueName ?? venueNameFromInput).trim();
    final hasRetrospectiveInput =
        _resultController.text.trim().isNotEmpty ||
        _issueController.text.trim().isNotEmpty ||
        _solutionController.text.trim().isNotEmpty ||
        _nextController.text.trim().isNotEmpty;
    final hasExplicitRetrospectiveChecked =
        widget.initialData?.containsKey('retrospectiveChecked') == true;
    final retrospectiveChecked = hasExplicitRetrospectiveChecked
        ? (widget.initialData?['retrospectiveChecked'] == true)
        : hasRetrospectiveInput;

    if (venueName.isEmpty && _selectedVenueId != null) {
      final venueDoc = await FirebaseFirestore.instance
          .collection('venues')
          .doc(_selectedVenueId)
          .get();
      venueName = (venueDoc.data()?['name'] ?? '').toString();
    }

    final customerTags = <String>[if (_isTra) 'トラ', if (_isOpe) 'オペ'];

    final data = {
      'customerName': _customerController.text.trim(),
      'customerTags': customerTags,
      'isTra': _isTra,
      'isOpe': _isOpe,
      'staffName': _staffController.text.trim(),
      'bookingDate': _dateController.text.trim(),
      'remarks': _remarksController.text.trim(),
      'handover': _handoverController.text.trim(),
      'retrospectiveResult': _resultController.text.trim(),
      'retrospectiveIssue': _issueController.text.trim(),
      'retrospectiveSolution': _solutionController.text.trim(),
      'retrospectiveNext': _nextController.text.trim(),
      'retrospectiveChecked': retrospectiveChecked,
      'venueId': _selectedVenueId,
      'venueName': venueName,
      ..._buildBookingSearchIndex(
        customerName: _customerController.text.trim(),
        venueName: venueName,
      ),
      'imageUrls': [..._existingUrls, ...newUrls],
      'pdfUrls': [..._existingPdfUrls],
      'pdfFileNames': [..._existingPdfNames],
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

    _invalidateSearchQueryCache(namespace: 'bookings');
  }

  // --- UI Helpers ---

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _handleBackPressed() async {
    if (!_isEditMode) {
      Navigator.pop(context);
      return;
    }

    if (_buildBookingDraftSignature() == _lastSavedDraftSignature) {
      Navigator.pop(context);
      return;
    }

    await _save(closeOnSuccess: true, showValidationError: true);
  }

  @override
  Widget build(BuildContext context) {
    final leadingSlotWidth = _isEditMode ? 160.0 : 56.0;

    return PopScope(
      canPop: !_isEditMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isEditMode) {
          unawaited(_handleBackPressed());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leadingWidth: leadingSlotWidth,
          centerTitle: true,
          titleSpacing: 0,
          leading: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              BackButton(onPressed: _handleBackPressed),
              if (_isEditMode)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isUploading
                                ? Icons.sync
                                : Icons.check_circle_outline,
                            size: 20,
                            color: _isUploading ? Colors.orange : Colors.green,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isUploading ? '自動保存中...' : '自動保存',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _isUploading
                                  ? Colors.orange
                                  : Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
                  if (widget.docId != null) _buildCustomerTagSelector(),
                  _buildTextField(_staffController, '担当者', maxLines: 3),
                  _buildDatePicker(),
                  const SizedBox(height: 24),
                  _buildImageSection(),
                  const SizedBox(height: 24),
                  _buildTextField(_remarksController, '備考', maxLines: 3),
                  _buildTextField(_handoverController, '引継ぎ事項', maxLines: 3),
                  const SizedBox(height: 8),
                  const Text(
                    '振り返り',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(_resultController, '成果', maxLines: 3),
                  _buildTextField(_issueController, '課題', maxLines: 3),
                  _buildTextField(_solutionController, '解決策', maxLines: 3),
                  _buildTextField(_nextController, '次回へ', maxLines: 3),
                  const SizedBox(height: 40),
                  if (!_isEditMode) _buildSaveButton(),
                  const SizedBox(height: 100),
                ],
              ),
            ),
            if (_isUploading && !_isEditMode) _buildLoadingOverlay(),
          ],
        ),
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
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
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
            _scheduleVenueSearchUpdate(v);
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
            child: StreamBuilder<List<_SearchResultDocument>>(
              stream: _buildIndexedSearchStream(
                cacheNamespace: 'venues',
                collection: FirebaseFirestore.instance.collection('venues'),
                searchQuery: _venueSearchQuery,
                idleLimit: _venuePickerSearchCandidateLimit,
                searchLimit: _venuePickerSearchCandidateLimit,
                fallbackQueryBuilder: (collection, limit) =>
                    collection.orderBy('name').limit(limit),
              ),
              builder: (context, snap) {
                if (snap.hasData) {
                  _lastVenuePickerDocs = snap.data!;
                }
                final searchDocs = snap.data ?? _lastVenuePickerDocs;
                if (searchDocs.isEmpty && !snap.hasData) {
                  return const LinearProgressIndicator();
                }
                final query = _venueSearchQuery;
                final matchesQuery = _createFuzzyMatcher(
                  query,
                  enableSubsequence: false,
                  enableEditDistance: false,
                );
                final filtered = searchDocs.where((d) {
                  final data = d.data;
                  final searchable = _buildVenueSearchSourceFromData(data);
                  return matchesQuery(searchable);
                }).toList();

                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final data = filtered[i].data;
                    final venueName = (data['name'] ?? '').toString();
                    final shopAndRoom = (data['shopAndRoom'] ?? '').toString();
                    return ListTile(
                      title: Text(venueName),
                      subtitle: Text(shopAndRoom.isEmpty ? '-' : shopAndRoom),
                      onTap: () {
                        setState(() {
                          _selectedVenueId = filtered[i].id;
                          _selectedVenueName = venueName;
                          _venueSearchController.text = venueName;
                          _venueSearchQuery = venueName;
                          _showVenueList = false;
                        });
                        _scheduleAutoSave();
                      },
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
    final isSingleLine = maxLines <= 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextField(
        controller: controller,
        minLines: maxLines,
        maxLines: isSingleLine ? 1 : null,
        keyboardType: isSingleLine
            ? TextInputType.text
            : TextInputType.multiline,
        textInputAction: isSingleLine
            ? TextInputAction.next
            : TextInputAction.newline,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: isUrgent
              ? const TextStyle(color: Colors.redAccent)
              : null,
        ),
      ),
    );
  }

  Widget _buildCustomerTagSelector() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        children: [
          FilterChip(
            label: const Text('トラ'),
            selected: _isTra,
            onSelected: (selected) {
              setState(() => _isTra = selected);
              _scheduleAutoSave();
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('オペ'),
            selected: _isOpe,
            onSelected: (selected) {
              setState(() => _isOpe = selected);
              _scheduleAutoSave();
            },
          ),
        ],
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
          final currentValue = _dateController.text.trim();
          DateTime initialDate = DateTime.now();
          if (currentValue.isNotEmpty) {
            try {
              initialDate = DateFormat('yyyy/MM/dd').parseStrict(currentValue);
            } catch (_) {
              initialDate = DateTime.now();
            }
          }

          final firstDate = DateTime(2000, 1, 1);
          final lastDate = DateTime(2100, 12, 31);
          if (initialDate.isBefore(firstDate) ||
              initialDate.isAfter(lastDate)) {
            initialDate = DateTime.now();
          }

          final d = await showDatePicker(
            context: context,
            initialDate: initialDate,
            firstDate: firstDate,
            lastDate: lastDate,
            locale: const Locale('ja'),
          );
          if (d != null) {
            setState(
              () => _dateController.text = DateFormat('yyyy/MM/dd').format(d),
            );
            _scheduleAutoSave();
          }
        },
      ),
    );
  }

  Widget _buildImageSection() {
    final hasMedia =
        _existingUrls.isNotEmpty ||
        _newImages.isNotEmpty ||
        _existingPdfUrls.isNotEmpty;

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
                  _scheduleAutoSave();
                },
                onEdit: () => _openAnnotationFromUrl(url),
              ),
            ),
            // 新規画像
            ..._newImages.map(
              (image) => _buildImageTile(
                bytes: image.bytes,
                onRemove: () {
                  setState(() => _newImages.remove(image));
                  _scheduleAutoSave();
                },
                onEdit: () => _openAnnotationFromPendingImage(image),
              ),
            ),
            // 既存PDF
            ..._existingPdfUrls.asMap().entries.map(
              (entry) => FutureBuilder<String>(
                future: _resolvePdfDisplayName(
                  entry.value,
                  preferredName: entry.key < _existingPdfNames.length
                      ? _existingPdfNames[entry.key]
                      : null,
                ),
                builder: (context, snapshot) {
                  final resolvedLabel =
                      (snapshot.data ??
                              (entry.key < _existingPdfNames.length
                                  ? _existingPdfNames[entry.key]
                                  : '保存済みPDF'))
                          .trim();
                  final label = resolvedLabel.isEmpty
                      ? '保存済みPDF'
                      : resolvedLabel;
                  return _buildPdfTile(
                    label: label,
                    onOpen: () => _openPdfWithExternalApp(entry.value),
                    onRemove: () {
                      setState(() {
                        _existingPdfUrls.removeAt(entry.key);
                        if (entry.key < _existingPdfNames.length) {
                          _existingPdfNames.removeAt(entry.key);
                        }
                      });
                      _scheduleAutoSave();
                    },
                    onMemo: () => _createPdfMemoWithPen(label),
                  );
                },
              ),
            ),
            // 追加ボタン
            _buildAddImageButton(),
          ],
        ),
        if (!hasMedia)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '写真はまだありません',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _buildImageTile({
    String? url,
    Uint8List? bytes,
    required VoidCallback onRemove,
    VoidCallback? onEdit,
  }) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 80,
            height: 80,
            child: url != null
                ? Image.network(
                    url,
                    fit: BoxFit.cover,
                    cacheWidth: 320,
                    cacheHeight: 320,
                    filterQuality: FilterQuality.medium,
                  )
                : bytes != null
                ? Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: 320,
                    cacheHeight: 320,
                    filterQuality: FilterQuality.medium,
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: IconButton(
            icon: const Icon(Icons.cancel, color: Colors.red, size: 20),
            onPressed: onRemove,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ),
        if (onEdit != null)
          Positioned(
            bottom: 0,
            left: 0,
            child: GestureDetector(
              onTap: onEdit,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                  ),
                ),
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.edit, color: Colors.white, size: 14),
              ),
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

  Widget _buildPdfTile({
    required String label,
    required VoidCallback onOpen,
    required VoidCallback onRemove,
    required VoidCallback onMemo,
  }) {
    return Stack(
      children: [
        GestureDetector(
          onTap: onOpen,
          child: Container(
            width: 120,
            height: 80,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0E0E0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.picture_as_pdf, color: Colors.red),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: IconButton(
            icon: const Icon(Icons.cancel, color: Colors.red, size: 20),
            onPressed: onRemove,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          child: GestureDetector(
            onTap: onMemo,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8)),
              ),
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.draw, color: Colors.white, size: 14),
            ),
          ),
        ),
      ],
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

// ─────────────────────────────────────────────────────────
// Photo Annotation (ペン描画)
// ─────────────────────────────────────────────────────────

class _DrawnStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool isEraser;

  _DrawnStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isEraser = false,
  });
}

class _TextAnnotation {
  final String text;
  final Offset position;
  final Color color;
  final double fontSize;

  const _TextAnnotation({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
  });

  _TextAnnotation copyWith({
    String? text,
    Offset? position,
    Color? color,
    double? fontSize,
  }) {
    return _TextAnnotation(
      text: text ?? this.text,
      position: position ?? this.position,
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class _StrokesPainter extends CustomPainter {
  final List<_DrawnStroke> strokes;
  final _DrawnStroke? currentStroke;
  final List<_TextAnnotation> textAnnotations;

  const _StrokesPainter({
    required this.strokes,
    required this.currentStroke,
    required this.textAnnotations,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in [...strokes, ?currentStroke]) {
      _drawStroke(canvas, stroke);
    }
    for (final annotation in textAnnotations) {
      _drawText(canvas, annotation);
    }
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, _DrawnStroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
        stroke.strokeWidth / 2,
        Paint()
          ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
          ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (int i = 1; i < stroke.points.length - 1; i++) {
      final midX = (stroke.points[i].dx + stroke.points[i + 1].dx) / 2;
      final midY = (stroke.points[i].dy + stroke.points[i + 1].dy) / 2;
      path.quadraticBezierTo(
        stroke.points[i].dx,
        stroke.points[i].dy,
        midX,
        midY,
      );
    }
    path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
    canvas.drawPath(path, paint);
  }

  void _drawText(Canvas canvas, _TextAnnotation annotation) {
    final painter = TextPainter(
      text: TextSpan(
        text: annotation.text,
        style: TextStyle(
          color: annotation.color,
          fontSize: annotation.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(canvas, annotation.position);
  }

  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}

class PhotoAnnotationPage extends StatefulWidget {
  final Uint8List? imageBytes;
  final String title;
  final Color canvasBackgroundColor;

  const PhotoAnnotationPage({
    super.key,
    required this.imageBytes,
    this.title = '写真に書き込み',
  }) : canvasBackgroundColor = Colors.black;

  const PhotoAnnotationPage.blank({super.key, this.title = 'メモに書き込み'})
    : imageBytes = null,
      canvasBackgroundColor = Colors.white;

  @override
  State<PhotoAnnotationPage> createState() => _PhotoAnnotationPageState();
}

class _PhotoAnnotationPageState extends State<PhotoAnnotationPage> {
  final List<_DrawnStroke> _strokes = [];
  final List<_DrawnStroke> _redoStack = [];
  final List<_TextAnnotation> _textAnnotations = [];
  _DrawnStroke? _currentStroke;
  Color _penColor = Colors.red;
  double _strokeWidth = 4.0;
  double _eraserWidth = 24.0;
  bool _isErasing = false;
  bool _isTextMode = false;
  bool _isZoomMode = false;
  double _viewScale = 1.0;
  double _viewRotation = 0.0;
  Offset _viewOffset = Offset.zero;
  Offset? _mousePos;
  int? _activeDrawPointer;
  int? _activePanPointer;
  Offset _panStartViewport = Offset.zero;
  Offset _panStartOffset = Offset.zero;
  int _scalePointerCount = 0;
  double _scaleStartViewScale = 1.0;
  double _scaleStartViewRotation = 0.0;
  Offset _scaleStartViewOffset = Offset.zero;
  Offset _scaleStartFocalCanvas = Offset.zero;
  Offset _scaleStartFocalViewport = Offset.zero;
  int? _activeTextPointer;
  int? _activeTextIndex;
  Offset _textDragStartCanvas = Offset.zero;
  Offset _textDragStartPosition = Offset.zero;
  int? _hoveredTextIndex;
  bool _suppressNextTextTap = false;
  final _repaintKey = GlobalKey();
  ui.Image? _uiImage;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _uiImage?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final sourceBytes = widget.imageBytes;
    if (sourceBytes == null) return;
    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _uiImage = frame.image);
  }

  void _updateMousePos(Offset? nextPosition) {
    if (_mousePos == nextPosition) return;
    setState(() => _mousePos = nextPosition);
  }

  Rect _annotationBounds(_TextAnnotation annotation) {
    final painter = TextPainter(
      text: TextSpan(
        text: annotation.text,
        style: TextStyle(
          color: annotation.color,
          fontSize: annotation.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return Rect.fromLTWH(
      annotation.position.dx,
      annotation.position.dy,
      painter.width,
      painter.height,
    );
  }

  int? _hitTestTextAnnotation(Offset canvasPoint) {
    for (var index = _textAnnotations.length - 1; index >= 0; index--) {
      final bounds = _annotationBounds(_textAnnotations[index]).inflate(10);
      if (bounds.contains(canvasPoint)) {
        return index;
      }
    }
    return null;
  }

  static const _colorOptions = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.white,
    Colors.black,
  ];

  static const double _minViewScale = 0.5;
  static const double _maxViewScale = 6.0;

  Offset _rotateOffset(Offset offset, double angle) {
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    return Offset(
      offset.dx * cosA - offset.dy * sinA,
      offset.dx * sinA + offset.dy * cosA,
    );
  }

  Offset _viewportToCanvas(Offset point) {
    return _rotateOffset(point - _viewOffset, -_viewRotation) / _viewScale;
  }

  void _zoomAt(Offset viewportPoint, double scaleDelta) {
    final canvasPoint = _viewportToCanvas(viewportPoint);
    final nextScale = (_viewScale * scaleDelta).clamp(
      _minViewScale,
      _maxViewScale,
    );
    setState(() {
      _viewScale = nextScale;
      _viewOffset =
          viewportPoint -
          _rotateOffset(canvasPoint * _viewScale, _viewRotation);
    });
  }

  void _rotateView(double angle) {
    final box = _repaintKey.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    final center = Offset(size.width / 2, size.height / 2);
    final centerCanvas = _viewportToCanvas(center);
    final quarterTurns = ((_viewRotation + angle) / (math.pi / 2)).round();
    final newRotation = quarterTurns * (math.pi / 2);
    final newOffset =
        center - _rotateOffset(centerCanvas * _viewScale, newRotation);
    setState(() {
      _viewRotation = newRotation;
      _viewOffset = newOffset;
    });
  }

  void _resetView() {
    setState(() {
      _viewScale = 1.0;
      _viewRotation = 0.0;
      _viewOffset = Offset.zero;
    });
  }

  void _setZoomMode(bool enabled) {
    setState(() {
      _isZoomMode = enabled;
      _currentStroke = null;
      _activeDrawPointer = null;
      _activePanPointer = null;
      _activeTextPointer = null;
      _activeTextIndex = null;
      _hoveredTextIndex = null;
      _suppressNextTextTap = false;
      _mousePos = enabled ? null : _mousePos;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isZoomMode) {
      if (_isZoomMode &&
          event.kind == PointerDeviceKind.mouse &&
          event.buttons == kSecondaryMouseButton) {
        _activePanPointer = event.pointer;
        _panStartViewport = event.localPosition;
        _panStartOffset = _viewOffset;
      }
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    final hitTextIndex = _hitTestTextAnnotation(canvasPoint);
    if (hitTextIndex != null) {
      _activeTextPointer = event.pointer;
      _activeTextIndex = hitTextIndex;
      _textDragStartCanvas = canvasPoint;
      _textDragStartPosition = _textAnnotations[hitTextIndex].position;
      _suppressNextTextTap = true;
      return;
    }

    if (_isTextMode) {
      return;
    }

    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons == kSecondaryMouseButton) {
      _activePanPointer = event.pointer;
      _panStartViewport = event.localPosition;
      _panStartOffset = _viewOffset;
      return;
    }

    if (_activePanPointer != null) return;

    if (event.buttons == kPrimaryMouseButton ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.mouse) {
      _activeDrawPointer = event.pointer;
      final canvasPoint = _viewportToCanvas(event.localPosition);
      setState(() {
        _mousePos = canvasPoint;
        _currentStroke = _DrawnStroke(
          points: [canvasPoint],
          color: _penColor,
          strokeWidth: _isErasing ? _eraserWidth : _strokeWidth,
          isEraser: _isErasing,
        );
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_activePanPointer == event.pointer) {
      setState(() {
        _viewOffset =
            _panStartOffset + (event.localPosition - _panStartViewport);
      });
      return;
    }

    if (_activeTextPointer == event.pointer && _activeTextIndex != null) {
      final canvasPoint = _viewportToCanvas(event.localPosition);
      final nextPosition =
          _textDragStartPosition + (canvasPoint - _textDragStartCanvas);
      setState(() {
        _textAnnotations[_activeTextIndex!] =
            _textAnnotations[_activeTextIndex!].copyWith(
              position: nextPosition,
            );
      });
      return;
    }

    if (_isZoomMode) return;

    if (_activeDrawPointer != event.pointer || _currentStroke == null) {
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    setState(() {
      _mousePos = canvasPoint;
      _currentStroke?.points.add(canvasPoint);
    });
  }

  void _finishPointer(int pointer) {
    if (_activePanPointer == pointer) {
      _activePanPointer = null;
    }
    if (_activeTextPointer == pointer) {
      _activeTextPointer = null;
      _activeTextIndex = null;
    }
    if (_activeDrawPointer != pointer) return;
    setState(() {
      if (_currentStroke != null) {
        _strokes.add(_currentStroke!);
        _redoStack.clear();
        _currentStroke = null;
      }
    });
    _activeDrawPointer = null;
  }

  void _handleHover(PointerHoverEvent event) {
    if (_isZoomMode) {
      _updateMousePos(null);
      if (_hoveredTextIndex != null) {
        setState(() => _hoveredTextIndex = null);
      }
      return;
    }

    final canvasPoint = _viewportToCanvas(event.localPosition);
    final nextHoveredIndex = _hitTestTextAnnotation(canvasPoint);
    if (_hoveredTextIndex != nextHoveredIndex) {
      setState(() => _hoveredTextIndex = nextHoveredIndex);
    }

    _updateMousePos(_isErasing ? canvasPoint : null);
  }

  Future<void> _showTextInputDialog(Offset canvasPosition) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('文字を追加'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(hintText: '入力してください'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('追加'),
            ),
          ],
        );
      },
    );

    if (!mounted || text == null) return;
    final value = text.trim();
    if (value.isEmpty) return;

    setState(() {
      _textAnnotations.add(
        _TextAnnotation(
          text: value,
          position: canvasPosition,
          color: _penColor,
          fontSize: 20.0,
        ),
      );
    });
  }

  void _handleTapUp(TapUpDetails details) {
    if (!_isTextMode || _isZoomMode) return;
    if (_suppressNextTextTap) {
      _suppressNextTextTap = false;
      return;
    }
    _showTextInputDialog(_viewportToCanvas(details.localPosition));
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final isTrackpad = event.kind == PointerDeviceKind.trackpad;
    final zoomDelta = isTrackpad ? event.scrollDelta.dy : -event.scrollDelta.dy;
    final zoomFactor = math.exp(zoomDelta / 120);
    _zoomAt(event.localPosition, zoomFactor);
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (details.pointerCount < 2) {
      if (_isZoomMode) {
        _scalePointerCount = 1;
        _scaleStartViewScale = _viewScale;
        _scaleStartViewRotation = _viewRotation;
        _scaleStartViewOffset = _viewOffset;
        _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
        _scaleStartFocalViewport = details.localFocalPoint;
      }
      return;
    }
    _scalePointerCount = 1;
    _scaleStartViewScale = _viewScale;
    _scaleStartViewRotation = _viewRotation;
    _scaleStartViewOffset = _viewOffset;
    _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
    _scaleStartFocalViewport = details.localFocalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (!_isZoomMode && details.pointerCount < 2) {
      return;
    }
    if (details.pointerCount < 2) {
      if (_scalePointerCount != 1) {
        _scalePointerCount = 1;
        _scaleStartViewOffset = _viewOffset;
        _scaleStartFocalViewport = details.localFocalPoint;
        return;
      }

      setState(() {
        _viewOffset =
            _scaleStartViewOffset +
            (details.localFocalPoint - _scaleStartFocalViewport);
      });
      _scalePointerCount = details.pointerCount;
      return;
    }

    if (_scalePointerCount < 2) {
      _scaleStartViewScale = _viewScale;
      _scaleStartViewRotation = _viewRotation;
      _scaleStartViewOffset = _viewOffset;
      _scaleStartFocalCanvas = _viewportToCanvas(details.localFocalPoint);
      _scaleStartFocalViewport = details.localFocalPoint;
    }
    _scalePointerCount = details.pointerCount;

    final newScale = (_scaleStartViewScale * details.scale).clamp(
      _minViewScale,
      _maxViewScale,
    );
    final newRotation = _scaleStartViewRotation;
    final newOffset =
        details.localFocalPoint -
        _rotateOffset(_scaleStartFocalCanvas * newScale, newRotation);
    setState(() {
      _viewScale = newScale;
      _viewRotation = newRotation;
      _viewOffset = newOffset;
    });
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _scalePointerCount = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.canvasBackgroundColor,
      appBar: AppBar(
        backgroundColor: widget.canvasBackgroundColor,
        foregroundColor: widget.canvasBackgroundColor == Colors.black
            ? Colors.white
            : Colors.black,
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: MouseRegion(
                cursor: _isZoomMode
                    ? SystemMouseCursors.grab
                    : (_activeTextPointer != null
                          ? SystemMouseCursors.grabbing
                          : (_hoveredTextIndex != null
                                ? SystemMouseCursors.move
                                : (_isErasing
                                      ? SystemMouseCursors.none
                                      : SystemMouseCursors.precise))),
                onHover: _handleHover,
                onExit: (_) => _updateMousePos(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTapUp,
                  onScaleStart: _handleScaleStart,
                  onScaleUpdate: _handleScaleUpdate,
                  onScaleEnd: _handleScaleEnd,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: (event) => _finishPointer(event.pointer),
                    onPointerCancel: (event) => _finishPointer(event.pointer),
                    onPointerSignal: _handlePointerSignal,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Transform(
                          transform: Matrix4.identity()
                            ..translateByDouble(
                              _viewOffset.dx,
                              _viewOffset.dy,
                              0,
                              1,
                            )
                            ..rotateZ(_viewRotation)
                            ..scaleByDouble(_viewScale, _viewScale, 1, 1),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (widget.imageBytes != null)
                                Image.memory(
                                  widget.imageBytes!,
                                  fit: BoxFit.contain,
                                )
                              else
                                Container(color: Colors.white),
                              CustomPaint(
                                painter: _StrokesPainter(
                                  strokes: _strokes,
                                  currentStroke: _currentStroke,
                                  textAnnotations: _textAnnotations,
                                ),
                                child: Container(color: Colors.transparent),
                              ),
                              if (!_isZoomMode &&
                                  _isErasing &&
                                  _mousePos != null)
                                Positioned(
                                  left: _mousePos!.dx - _eraserWidth / 2,
                                  top: _mousePos!.dy - _eraserWidth / 2,
                                  child: IgnorePointer(
                                    child: Container(
                                      width: _eraserWidth,
                                      height: _eraserWidth,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // カラーパレット
              for (final color in _colorOptions)
                GestureDetector(
                  onTap: _isZoomMode
                      ? null
                      : () => setState(() {
                          _penColor = color;
                          _isErasing = false;
                        }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: !_isErasing && _penColor == color
                            ? Colors.white
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              Icon(
                _isZoomMode
                    ? Icons.zoom_in_map
                    : (_isErasing ? Icons.auto_fix_normal : Icons.brush),
                color: Colors.white54,
                size: 18,
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 100,
                child: Slider(
                  value: _isErasing ? _eraserWidth : _strokeWidth,
                  min: 2,
                  max: _isErasing ? 60 : 20,
                  onChanged: _isZoomMode
                      ? null
                      : (v) => setState(() {
                          if (_isErasing) {
                            _eraserWidth = v;
                          } else {
                            _strokeWidth = v;
                          }
                        }),
                  activeColor: _isErasing ? Colors.white54 : _penColor,
                  inactiveColor: Colors.white24,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.start,
            children: [
              _buildActionButton(
                icon: Icons.zoom_in_map,
                label: 'ズーム',
                onPressed: () => _setZoomMode(!_isZoomMode),
                emphasized: _isZoomMode,
              ),
              _buildActionButton(
                icon: Icons.undo,
                label: '元に戻す',
                onPressed: _strokes.isEmpty ? null : _undo,
              ),
              _buildActionButton(
                icon: Icons.redo,
                label: 'やり直し',
                onPressed: _redoStack.isEmpty ? null : _redo,
              ),
              _buildActionButton(
                icon: Icons.center_focus_strong,
                label: 'リセット',
                onPressed: _resetView,
              ),
              _buildActionButton(
                icon: Icons.title,
                label: '文字',
                onPressed: _isZoomMode
                    ? null
                    : () => setState(() {
                        _isTextMode = !_isTextMode;
                        _isErasing = false;
                      }),
                emphasized: !_isZoomMode && _isTextMode,
              ),
              _buildActionButton(
                icon: Icons.auto_fix_normal,
                label: '消しゴム',
                onPressed: _isZoomMode
                    ? null
                    : () => setState(() => _isErasing = !_isErasing),
                emphasized: !_isZoomMode && _isErasing,
              ),
              _buildActionButton(
                icon: Icons.delete_outline,
                label: 'クリア',
                onPressed: _strokes.isEmpty && _textAnnotations.isEmpty
                    ? null
                    : _clear,
              ),
              _buildActionButton(
                icon: Icons.save,
                label: '保存',
                onPressed: _save,
                emphasized: !_isErasing,
              ),
              if (_isZoomMode) ...[
                _buildActionButton(
                  icon: Icons.zoom_out,
                  label: '縮小',
                  onPressed: () => _zoomAt(const Offset(200, 200), 0.85),
                ),
                _buildActionButton(
                  icon: Icons.zoom_in,
                  label: '拡大',
                  onPressed: () => _zoomAt(const Offset(200, 200), 1.18),
                ),
                _buildActionButton(
                  icon: Icons.rotate_left,
                  label: '左回転',
                  onPressed: () => _rotateView(-math.pi / 2),
                ),
                _buildActionButton(
                  icon: Icons.rotate_right,
                  label: '右回転',
                  onPressed: () => _rotateView(math.pi / 2),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool emphasized = false,
  }) {
    final foreground = emphasized ? Colors.black : Colors.white;
    final background = emphasized ? Colors.white : Colors.white12;
    return SizedBox(
      height: 40,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: Colors.white10,
          disabledForegroundColor: Colors.white38,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  void _undo() => setState(() => _redoStack.add(_strokes.removeLast()));
  void _redo() => setState(() => _strokes.add(_redoStack.removeLast()));
  void _clear() => setState(() {
    _redoStack.addAll(_strokes.reversed);
    _strokes.clear();
    _textAnnotations.clear();
  });

  Future<void> _save() async {
    final srcImage = _uiImage;
    final box = _repaintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      if (mounted) Navigator.pop(context);
      return;
    }

    if (srcImage == null) {
      final repaint =
          _repaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (repaint == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final image = await repaint.toImage(pixelRatio: 2.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null || !mounted) return;
      Navigator.pop(context, png.buffer.asUint8List());
      return;
    }

    final imgW = srcImage.width.toDouble();
    final imgH = srcImage.height.toDouble();
    final conW = box.size.width;
    final conH = box.size.height;

    // BoxFit.contain の表示領域を計算してストロークの座標を逆変換
    double displayW, displayH, offsetX, offsetY;
    if (imgW / imgH > conW / conH) {
      displayW = conW;
      displayH = conW * imgH / imgW;
      offsetX = 0;
      offsetY = (conH - displayH) / 2;
    } else {
      displayH = conH;
      displayW = conH * imgW / imgH;
      offsetX = (conW - displayW) / 2;
      offsetY = 0;
    }
    final scale = imgW / displayW;

    // 1. ストロークレイヤーを別途作成（透明背景、消しゴムはここだけで有効）
    final strokeRecorder = ui.PictureRecorder();
    final strokeCanvas = Canvas(strokeRecorder);
    strokeCanvas.saveLayer(Rect.fromLTWH(0, 0, imgW, imgH), Paint());
    for (final stroke in _strokes) {
      _paintScaledStroke(strokeCanvas, stroke, offsetX, offsetY, scale);
    }
    strokeCanvas.restore();
    final strokePicture = strokeRecorder.endRecording();
    final strokeImage = await strokePicture.toImage(
      srcImage.width,
      srcImage.height,
    );

    // 2. 元画像 + ストロークレイヤーを合成
    final compositeRecorder = ui.PictureRecorder();
    final compositeCanvas = Canvas(compositeRecorder);
    compositeCanvas.drawImage(srcImage, Offset.zero, Paint());
    compositeCanvas.drawImage(strokeImage, Offset.zero, Paint());
    for (final annotation in _textAnnotations) {
      final scaledPosition = Offset(
        (annotation.position.dx - offsetX) * scale,
        (annotation.position.dy - offsetY) * scale,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: annotation.text,
          style: TextStyle(
            color: annotation.color,
            fontSize: annotation.fontSize * scale,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      textPainter.paint(compositeCanvas, scaledPosition);
    }
    final compositePicture = compositeRecorder.endRecording();
    final compositeImage = await compositePicture.toImage(
      srcImage.width,
      srcImage.height,
    );

    // 3. プレビューの回転をそのまま最終画像に適用
    final rotation = _viewRotation;
    final cosR = math.cos(rotation).abs();
    final sinR = math.sin(rotation).abs();
    final outW = (imgW * cosR + imgH * sinR).round();
    final outH = (imgW * sinR + imgH * cosR).round();

    final rotatedRecorder = ui.PictureRecorder();
    final rotatedCanvas = Canvas(rotatedRecorder);
    rotatedCanvas.translate(outW / 2, outH / 2);
    rotatedCanvas.rotate(rotation);
    rotatedCanvas.translate(-imgW / 2, -imgH / 2);
    rotatedCanvas.drawImage(compositeImage, Offset.zero, Paint());
    final rotatedPicture = rotatedRecorder.endRecording();
    final out = await rotatedPicture.toImage(outW, outH);

    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    Navigator.pop(context, data.buffer.asUint8List());
  }

  void _paintScaledStroke(
    Canvas canvas,
    _DrawnStroke stroke,
    double offsetX,
    double offsetY,
    double scale,
  ) {
    if (stroke.points.isEmpty) return;
    final scaled = stroke.points
        .map((p) => Offset((p.dx - offsetX) * scale, (p.dy - offsetY) * scale))
        .toList();
    final paint = Paint()
      ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
      ..strokeWidth = stroke.strokeWidth * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (scaled.length == 1) {
      canvas.drawCircle(
        scaled.first,
        stroke.strokeWidth * scale / 2,
        Paint()
          ..color = stroke.isEraser ? const Color(0x00000000) : stroke.color
          ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(scaled.first.dx, scaled.first.dy);
    for (int i = 1; i < scaled.length - 1; i++) {
      final midX = (scaled[i].dx + scaled[i + 1].dx) / 2;
      final midY = (scaled[i].dy + scaled[i + 1].dy) / 2;
      path.quadraticBezierTo(scaled[i].dx, scaled[i].dy, midX, midY);
    }
    path.lineTo(scaled.last.dx, scaled.last.dy);
    canvas.drawPath(path, paint);
  }
}
