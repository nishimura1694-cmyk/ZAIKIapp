part of '../main.dart';

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
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('会場の削除'),
        content: const Text('この会場情報を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(ctx, true);
            },
            child: const Text('削除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final restoreData = Map<String, dynamic>.from(_currentData);
    final docId = widget.docId;

    await FirebaseFirestore.instance.collection('venues').doc(docId).delete();
    _invalidateSearchQueryCache(namespace: 'venues');
    if (context.mounted) Navigator.pop(context);

    messenger.showSnackBar(
      SnackBar(
        content: const Text('会場を削除しました'),
        action: SnackBarAction(
          label: '元に戻す',
          onPressed: () async {
            await FirebaseFirestore.instance
                .collection('venues')
                .doc(docId)
                .set(restoreData);
            _invalidateSearchQueryCache(namespace: 'venues');
            messenger.showSnackBar(
              const SnackBar(content: Text('会場を元に戻しました')),
            );
          },
        ),
      ),
    );
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
                color: AppColors.dividerGrey,
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
                                color: AppColors.danger,
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
                    _detailRow(Icons.place_outlined, '住所', data['address']),
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
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '履歴の取得に失敗しました',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 13,
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => setState(() {}),
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('再試行'),
                                  ),
                                ],
                              ),
                            );
                          }
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const LoadingView();
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
                            return const EmptyStateView(
                              icon: Icons.history,
                              message: '履歴がありません',
                            );
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
                                  showAppBottomSheet(
                                    context: context,
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
                                            color: AppColors.subtleFill,
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
                    const Divider(height: 40, color: AppColors.dividerGrey),
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
