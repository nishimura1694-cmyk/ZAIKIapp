part of '../main.dart';

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
    'https://docs.google.com/spreadsheets/d/e/2PACX-1vROAjaOGG82t-lfr_VfAplMDZiWx11E-VXnPHTH9i3EmMEetQMiDPppBmaPSZ4EJlWNj7RIuefbrRr7/pub?gid=0&single=true&output=csv';
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

/// シフト画面([ShiftSplitScreen])で日付ごとの列カードを描画するための、
/// ラベルと値のペア。以前は [DateExtractListScreen] と重複定義されていた。
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

