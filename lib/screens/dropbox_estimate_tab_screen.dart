part of '../main.dart';

// --- 月次見積データ（Dropbox見積データ抽出の結果を金額を除いてアプリに反映したもの) ---
class _MonthlyEstimateItem {
  final String category;
  final String name;
  final String? memo;
  final Object? qty;
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
      qty: json['qty'],
      duration: json['duration'],
    );
  }

  String get qtyDurationLabel {
    final parts = <String>[];
    if (qty != null) parts.add('数量:$qty');
    if (duration != null) parts.add('$duration');
    return parts.join(' / ');
  }
}

class _MonthlyEstimateJob {
  final String folder;
  final String? clientName;
  final String? deliveryAddress;
  final String? deliveryAddressDetail;
  final String? deliveryDate;
  final String? time;
  final String? returnTime;
  final String? note;
  final List<_MonthlyEstimateItem> items;

  const _MonthlyEstimateJob({
    required this.folder,
    this.clientName,
    this.deliveryAddress,
    this.deliveryAddressDetail,
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
      deliveryAddressDetail: json['deliveryAddressDetail']?.toString(),
      deliveryDate: json['deliveryDate']?.toString(),
      time: json['time']?.toString(),
      returnTime: json['returnTime']?.toString(),
      note: json['note']?.toString(),
      items: itemsJson
          .whereType<Map>()
          .map(
            (e) => _MonthlyEstimateItem.fromJson(Map<String, dynamic>.from(e)),
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

/// 見積案件(job)を一意に識別するキー。予約履歴への重複自動登録を防ぐために使う。
String _estimateJobId(_MonthlyEstimateJob job) {
  return '${job.deliveryDate ?? ''}_${job.folder}';
}

/// 会場タブ(Firestore の venues)から名前が完全一致する会場を探し、
/// 見つかればその ID を返す。見つかった会場の住所が未入力で、見積データ側に
/// 詳細住所(address)があれば、その場でフィールド単位で補完する(既に住所が
/// 入力済みの場合は上書きしない)。見つからなければ、名前と住所を設定した
/// 会場を新規登録して ID を返す(住所以外の詳細は空のままとし、後で編集できる
/// ようにする)。
Future<String?> _findOrCreateVenueByName(
  String venueName, {
  String? address,
}) async {
  final venuesRef = FirebaseFirestore.instance.collection('venues');
  final trimmedAddress = (address ?? '').trim();
  final existing = await venuesRef
      .where('name', isEqualTo: venueName)
      .limit(1)
      .get();
  if (existing.docs.isNotEmpty) {
    final doc = existing.docs.first;
    final existingAddress = (doc.data()['address'] ?? '').toString().trim();
    if (trimmedAddress.isNotEmpty && existingAddress.isEmpty) {
      await doc.reference.update({
        'address': trimmedAddress,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    return doc.id;
  }

  final docRef = await venuesRef.add({
    'name': venueName,
    'address': trimmedAddress,
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
    ..._buildVenueSearchIndex(venueName),
    'updatedAt': FieldValue.serverTimestamp(),
    'createdAt': FieldValue.serverTimestamp(),
  });
  return docRef.id;
}

/// 見積案件(job)に「車上」(車上渡しプランなど、現地設営を伴わない案件)が
/// 含まれるかどうかを、備考・機材項目(カテゴリ/品名/メモ)から判定する。
bool _estimateJobHasVehicleHandoff(_MonthlyEstimateJob job) {
  const keyword = '車上';
  if ((job.note ?? '').contains(keyword)) return true;
  for (final item in job.items) {
    if (item.category.contains(keyword) ||
        item.name.contains(keyword) ||
        (item.memo ?? '').contains(keyword)) {
      return true;
    }
  }
  return false;
}

/// 見積一覧の「予約履歴作成」ボタンを押した結果。
enum EstimateBookingCreationResult {
  /// 新規に予約履歴を作成した。
  created,

  /// 既にこの見積案件から予約履歴が作成済みだった。
  alreadyExists,

  /// 納品日が解釈できず、予約日を決定できなかった。
  invalidDate,
}

/// 見積案件(job) 1件を予約履歴(Firestore の bookings)として登録する。
/// 既に取り込み済みの案件(estimateJobId が一致するもの)は再登録しない。
/// 会場タブに同名の会場がなければ自動登録し、あれば住所が未入力の場合のみ補完する。
/// 「車上」(現地設営を伴わない車上渡し等)の場合でも作成自体は可能で、
/// 呼び出し側(見積一覧のボタン)で確認ポップアップを出したうえで呼び出す。
Future<EstimateBookingCreationResult> _createBookingFromEstimateJob(
  _MonthlyEstimateJob job,
) async {
  final date = job.parsedDeliveryDate;
  if (date == null) {
    return EstimateBookingCreationResult.invalidDate;
  }

  final bookingsRef = FirebaseFirestore.instance.collection('bookings');
  final estimateJobId = _estimateJobId(job);
  final existing = await bookingsRef
      .where('estimateJobId', isEqualTo: estimateJobId)
      .limit(1)
      .get();
  if (existing.docs.isNotEmpty) {
    return EstimateBookingCreationResult.alreadyExists;
  }

  final venueName = (job.deliveryAddress ?? '').trim();
  final venueId = venueName.isEmpty
      ? null
      : await _findOrCreateVenueByName(
          venueName,
          address: job.deliveryAddressDetail,
        );

  final bookingDate = DateFormat('yyyy/MM/dd').format(date);
  final customerName = (job.clientName ?? '').trim();

  await bookingsRef.add({
    'customerName': customerName,
    'customerTags': <String>[],
    'isTra': false,
    'isOpe': false,
    'staffName': '',
    'bookingDate': bookingDate,
    'remarks': '',
    'handover': '',
    'retrospectiveResult': '',
    'retrospectiveIssue': '',
    'retrospectiveSolution': '',
    'retrospectiveNext': '',
    'retrospectiveChecked': false,
    'venueId': venueId,
    'venueName': venueName,
    ..._buildBookingSearchIndex(
      customerName: customerName,
      venueName: venueName,
    ),
    'imageUrls': <String>[],
    'pdfUrls': <String>[],
    'pdfFileNames': <String>[],
    'estimateJobId': estimateJobId,
    'createdAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  });

  _invalidateSearchQueryCache(namespace: 'bookings');
  return EstimateBookingCreationResult.created;
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
    return await _loadAllBundledEstimateJobs(files);
  } catch (_) {
    // index.jsonが無い場合は空扱い
    return const [];
  }
}

/// 表示上限(「2か月先」の月末)までの範囲に入るデータだけを残す。
/// includePastがfalseの場合は本日より前の日付を除外し、trueの場合は
/// 「先月」の月初まで遡って表示する。
/// 日付が解釈できない(例:「秋ごろ」)場合は範囲外として非表示にする。
List<_MonthlyEstimateJob> _filterJobsWithinDisplayRange(
  List<_MonthlyEstimateJob> jobs,
  DateTime now, {
  required bool includePast,
}) {
  final rangeStart = includePast
      ? DateTime(now.year, now.month - 1, 1)
      : DateTime(now.year, now.month, now.day);
  final rangeEndExclusive = DateTime(now.year, now.month + 3, 1);
  return jobs
      .where((job) {
        final d = job.parsedDeliveryDate;
        if (d == null) return false;
        return !d.isBefore(rangeStart) && d.isBefore(rangeEndExclusive);
      })
      .toList(growable: false);
}

/// 表示範囲のラベル(例:「2026年7月〜2026年10月」「2026年8月27日〜2026年10月」)を組み立てる。
String _buildDisplayRangeLabel(DateTime now, {required bool includePast}) {
  final endMonth = DateTime(now.year, now.month + 2, 1);
  final endLabel = DateFormat('yyyy年M月').format(endMonth);
  if (includePast) {
    final startMonth = DateTime(now.year, now.month - 1, 1);
    return '${DateFormat('yyyy年M月').format(startMonth)}〜$endLabel';
  }
  return '${DateFormat('yyyy年M月d日').format(now)}〜$endLabel';
}

class _MonthlyEstimateJobTile extends StatefulWidget {
  final _MonthlyEstimateJob job;
  const _MonthlyEstimateJobTile({required this.job});

  @override
  State<_MonthlyEstimateJobTile> createState() =>
      _MonthlyEstimateJobTileState();
}

class _MonthlyEstimateJobTileState extends State<_MonthlyEstimateJobTile> {
  bool _isCreating = false;
  bool _checkedExistingBooking = false;
  EstimateBookingCreationResult? _result;

  @override
  void initState() {
    super.initState();
    _checkExistingBooking();
  }

  /// この見積案件からすでに予約履歴が作成済みかをFirestoreに問い合わせる。
  ///
  /// `_result` だけに頼ると、画面遷移で `_MonthlyEstimateJobTile` が
  /// 再構築されるたびに「登録済み」表示が消えてしまうため、実際の
  /// 予約履歴の有無で判定し直す。
  Future<void> _checkExistingBooking() async {
    try {
      final existing = await FirebaseFirestore.instance
          .collection('bookings')
          .where('estimateJobId', isEqualTo: _estimateJobId(widget.job))
          .limit(1)
          .get();
      if (!mounted) return;
      if (existing.docs.isNotEmpty) {
        setState(() => _result = EstimateBookingCreationResult.alreadyExists);
      }
    } catch (_) {
      // 取得に失敗した場合はボタン表示のままにし、押下時の重複チェックに任せる。
    } finally {
      if (mounted) setState(() => _checkedExistingBooking = true);
    }
  }

  Future<bool> _confirmVehicleHandoff() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('車上渡しの案件です'),
        content: const Text('この案件は「車上」(現地設営を伴わない車上渡し等)です。\nこのまま予約履歴を作成しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('作成する'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _handleCreateBooking() async {
    if (_isCreating) return;
    if (_estimateJobHasVehicleHandoff(widget.job)) {
      final confirmed = await _confirmVehicleHandoff();
      if (!mounted || !confirmed) return;
    }
    setState(() => _isCreating = true);
    try {
      final result = await _createBookingFromEstimateJob(widget.job);
      if (!mounted) return;
      setState(() => _result = result);
      final message = switch (result) {
        EstimateBookingCreationResult.created => '予約履歴を作成しました',
        EstimateBookingCreationResult.alreadyExists => '既に予約履歴が作成されています',
        EstimateBookingCreationResult.invalidDate => '納品日が不明なため作成できません',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('予約履歴の作成に失敗しました: $e')));
    } finally {
      if (mounted) {
        setState(() => _isCreating = false);
      }
    }
  }

  Widget _buildActionButton() {
    if (!_checkedExistingBooking) {
      return const SizedBox(
        height: 32,
        width: 32,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final isDone =
        _result == EstimateBookingCreationResult.created ||
        _result == EstimateBookingCreationResult.alreadyExists;
    if (isDone) {
      return const Chip(
        avatar: Icon(Icons.check_circle, size: 18, color: Colors.green),
        label: Text('予約履歴に登録済み'),
        visualDensity: VisualDensity.compact,
      );
    }
    return OutlinedButton.icon(
      onPressed: _isCreating ? null : _handleCreateBooking,
      icon: _isCreating
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.event_available, size: 18),
      label: Text(_isCreating ? '作成中...' : '予約履歴作成'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final subtitleParts = <String>[
      if (job.clientName != null && job.clientName!.isNotEmpty) job.clientName!,
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
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Align(
            alignment: Alignment.centerRight,
            child: _buildActionButton(),
          ),
        ),
      ],
    );
  }
}

class DropboxEstimateTabScreen extends StatefulWidget {
  const DropboxEstimateTabScreen({
    super.key,
    this.initialSearchQuery,
    this.initialDeliveryDate,
  });

  final String? initialSearchQuery;

  /// 予約履歴から遷移した場合の予約日（'yyyy/MM/dd'）。
  /// 検索語（顧客名）に加えてこの日付が一致する見積のみに絞り込むために使う。
  /// ユーザーが検索語を編集した時点で解除する。
  final String? initialDeliveryDate;

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
  bool _showPast = false;
  late final TextEditingController _searchController;
  String _searchQuery = '';
  DateTime? _strictDeliveryDate;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _localJobsFuture = _loadBundledEstimateJobsFromIndex();
    _searchQuery = widget.initialSearchQuery?.trim() ?? '';
    _strictDeliveryDate = _parseBookingDate(widget.initialDeliveryDate);
    _searchController = TextEditingController(text: _searchQuery);
    _searchController.addListener(() {
      final value = _searchController.text;
      if (_searchQuery == value) return;
      setState(() {
        _searchQuery = value;
        // 検索語をユーザーが編集したら、予約日による絞り込みは解除する。
        _strictDeliveryDate = null;
      });
    });
  }

  DateTime? _parseBookingDate(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    try {
      return DateFormat('yyyy/MM/dd').parseStrict(trimmed);
    } catch (_) {
      return null;
    }
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
    final searchQuery = _searchQuery.trim();
    final isSearching = searchQuery.isNotEmpty;
    return Scaffold(
      appBar: SearchAppBar(
        title: '見積抽出',
        controller: _searchController,
        hintText: '顧客名・搬入先で検索...',
        suffixIcon: isSearching
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => _searchController.clear(),
              )
            : null,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<List<_MonthlyEstimateJob>>(
        future: _localJobsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView();
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
          final jobs = isSearching
              ? (() {
                  final matchesQuery = _createFuzzyMatcher(
                    searchQuery,
                    enableSubsequence: false,
                    enableEditDistance: false,
                  );
                  final strictDate = _strictDeliveryDate;
                  return allJobs
                      .where(
                        (job) => matchesQuery(
                          '${job.clientName ?? ''} ${job.deliveryAddress ?? ''} ${job.folder}',
                        ),
                      )
                      .where((job) {
                        if (strictDate == null) return true;
                        final deliveryDate = job.parsedDeliveryDate;
                        return deliveryDate != null &&
                            _isSameDate(deliveryDate, strictDate);
                      })
                      .toList();
                })()
              : _filterJobsWithinDisplayRange(
                  allJobs,
                  now,
                  includePast: _showPast,
                );
          if (jobs.isEmpty) {
            return EmptyStateView(
              icon: Icons.description_outlined,
              message: isSearching ? '該当する見積データがありません' : '登録済みの見積データがありません',
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.center,
                  child: ToggleFilterButton(
                    isActive: _showPast,
                    icon: Icons.history,
                    activeIcon: Icons.visibility_off_rounded,
                    label: '過去分を表示',
                    activeLabel: '過去分を隠す',
                    onPressed: () => setState(() => _showPast = !_showPast),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    isSearching
                        ? '検索結果（金額非表示・${jobs.length}件）'
                        : '${_buildDisplayRangeLabel(now, includePast: _showPast)} 登録済み見積データ'
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
                    return SectionCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _MonthlyEstimateJobTile(job: jobs[index]),
                      ),
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
