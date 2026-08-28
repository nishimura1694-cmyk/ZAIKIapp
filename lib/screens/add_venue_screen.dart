part of '../main.dart';

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
        backgroundColor: AppColors.brandOrange,
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
    final currentValue = _venueAreaSectionOrder.contains(_selectedBlock)
        ? _selectedBlock
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: currentValue,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'エリア'),
            items: _venueAreaSectionOrder
                .map((area) => DropdownMenuItem(value: area, child: Text(area)))
                .toList(),
            onChanged: (value) {
              setState(() => _selectedBlock = value);
              _scheduleAutoSave();
            },
          ),
        ),
        const SizedBox(width: 8),
        if (currentValue != null)
          IconButton(
            icon: const Icon(Icons.info_outline, color: AppColors.brandOrange),
            tooltip: 'エリアの詳細を表示',
            onPressed: () => _showAreaDialog(currentValue),
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
      setState(() => _selectedBlock = detectedArea);
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
    final newItemController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        var isSubmitting = false;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> submitNewItem() async {
              if (isSubmitting) return;
              final value = newItemController.text.trim();
              if (value.isEmpty) return;
              setDialogState(() => isSubmitting = true);
              try {
                await FirebaseFirestore.instance
                    .collection(col)
                    .add({'name': value})
                    .timeout(const Duration(seconds: 10));
                newItemController.clear();
              } catch (e) {
                _showSnackBar('$labelの追加に失敗しました: $e');
              } finally {
                if (dialogContext.mounted) {
                  setDialogState(() => isSubmitting = false);
                }
              }
            }

            return AlertDialog(
              backgroundColor: AppColors.surface,
              surfaceTintColor: Colors.transparent,
              title: Text('$labelの管理'),
              content: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection(col)
                            .snapshots(),
                        builder: (context, snap) {
                          if (!snap.hasData) return const SizedBox();
                          if (snap.data!.docs.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text('項目がありません'),
                            );
                          }
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
                                      onPressed: () => _editItem(
                                        col,
                                        label,
                                        doc.id,
                                        doc['name'],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete,
                                        size: 20,
                                        color: AppColors.danger,
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
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newItemController,
                            enabled: !isSubmitting,
                            decoration: const InputDecoration(
                              hintText: '新しい項目名',
                            ),
                            onSubmitted: (_) => submitNewItem(),
                          ),
                        ),
                        const SizedBox(width: 4),
                        isSubmitting
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: AppColors.brandOrange,
                                ),
                                onPressed: submitNewItem,
                              ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('閉じる'),
                ),
              ],
            );
          },
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
        backgroundColor: AppColors.surface,
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
    return Scaffold(
      appBar: EditableAppBar(
        title: widget.docId == null ? '会場の登録' : '会場の編集',
        isEditMode: _isEditMode,
        isSaving: _isSaving,
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
                  icon: const Icon(Icons.my_location, color: AppColors.brandOrange),
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
                    backgroundColor: AppColors.brandOrange,
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
