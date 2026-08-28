part of '../main.dart';

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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('新規会場として登録'),
        content: Text('「$name」を新しい会場として登録しますか？\n住所などの詳細は後から会場一覧で編集できます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('登録'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

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
      final existingEstimateJobId = widget.initialData?['estimateJobId'];
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(widget.docId)
          .set({
            ...data,
            'createdAt': existingCreatedAt is Timestamp
                ? existingCreatedAt
                : null,
            if (existingEstimateJobId is String)
              'estimateJobId': existingEstimateJobId,
          });
    }

    _invalidateSearchQueryCache(namespace: 'bookings');
  }

  // --- UI Helpers ---

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirmDiscardChanges() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('入力内容を破棄しますか？'),
        content: const Text('保存せずに戻ると、入力した内容は失われます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '破棄する',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _handleBackPressed() async {
    final hasUnsavedChanges =
        _buildBookingDraftSignature() != _lastSavedDraftSignature;
    if (!hasUnsavedChanges) {
      Navigator.pop(context);
      return;
    }

    if (!_isEditMode) {
      final shouldDiscard = await _confirmDiscardChanges();
      if (shouldDiscard && mounted) {
        Navigator.pop(context);
      }
      return;
    }

    // 編集中の変更を保存しつつ、内容に不備があっても画面は必ず抜けられるようにする
    // (以前は保存に失敗すると無言で戻れなくなっていた)。
    await _save(closeOnSuccess: false, showValidationError: true);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBackPressed());
        }
      },
      child: Scaffold(
        appBar: EditableAppBar(
          title: widget.docId == null ? '予約の登録' : '予約の編集',
          isEditMode: _isEditMode,
          isSaving: _isUploading,
          onBack: _handleBackPressed,
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
                    icon: const Icon(
                      Icons.add_circle,
                      color: AppColors.brandOrange,
                    ),
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
              border: Border.all(color: AppColors.dividerGrey),
              borderRadius: BorderRadius.circular(8),
              color: AppColors.surface,
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
              ? const TextStyle(color: AppColors.danger)
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
          spacing: 12,
          runSpacing: 12,
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
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 14),
            ),
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
          color: AppColors.subtleFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.add_a_photo, color: AppColors.textSecondary),
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
              color: AppColors.subtleFill,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.dividerGrey),
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
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 14),
            ),
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
          backgroundColor: AppColors.brandOrange,
          disabledBackgroundColor: AppColors.brandOrange.withValues(
            alpha: 0.4,
          ), // 無効化時の色
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
