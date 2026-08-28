part of '../main.dart';

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
