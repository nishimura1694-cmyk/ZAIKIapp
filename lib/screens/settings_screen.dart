part of '../main.dart';

// --- 設定画面 ---
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _notificationsEnabled;
  AuthorizationStatus? _osPermissionStatus;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final enabled = await BookingNotificationService.instance.isEnabled();
    AuthorizationStatus? osStatus;
    if (!kIsWeb) {
      try {
        osStatus = await BookingNotificationService.instance
            .osPermissionStatus();
      } catch (_) {
        // 取得できない場合はOS側の注意書きを出さないだけにする
      }
    }
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = enabled;
      _osPermissionStatus = osStatus;
    });
  }

  Future<void> _handleToggle(bool value) async {
    setState(() => _isSaving = true);
    await BookingNotificationService.instance.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = value;
      _isSaving = false;
    });
  }

  String? get _osPermissionNote {
    if (_osPermissionStatus == AuthorizationStatus.denied) {
      return '端末の設定で通知がブロックされています。OSの設定アプリから許可してください。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _notificationsEnabled;
    final osNote = _osPermissionNote;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: enabled == null
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  child: SwitchListTile(
                    title: const Text('予約の更新通知'),
                    subtitle: const Text('新しい予約が登録されたときに通知します'),
                    value: enabled,
                    onChanged: _isSaving ? null : _handleToggle,
                    activeThumbColor: AppColors.brandOrange,
                  ),
                ),
                if (osNote != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerBackground,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: AppColors.danger,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            osNote,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
