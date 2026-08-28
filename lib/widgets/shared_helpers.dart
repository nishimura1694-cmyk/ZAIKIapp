part of '../main.dart';

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
            color: AppColors.subtleFill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value == null || value.isEmpty ? "-" : value,
                style: const TextStyle(
                  fontSize: 16,
                  color: AppColors.textPrimary,
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
