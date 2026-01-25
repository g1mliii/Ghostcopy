import 'package:flutter/material.dart';
import '../../models/clipboard_item.dart';
import '../../services/file_type_service.dart';
import '../theme/colors.dart' show GhostColors;

/// Widget to display a preview of a file/image clipboard item
class FilePreviewWidget extends StatelessWidget {
  const FilePreviewWidget({
    required this.item,
    super.key,
    this.compact = false,
  });

  final ClipboardItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final filename = item.metadata?.originalFilename ?? 'file';
    final icon = FileTypeService.instance.getFileIcon(item.contentType);
    final size = item.displaySize;

    if (compact) {
      return _buildCompactView(context, filename, icon, size);
    } else {
      return _buildFullView(context, filename, icon, size);
    }
  }

  Widget _buildCompactView(BuildContext context, String filename, IconData icon, String size) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: GhostColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 24,
            color: GhostColors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                filename,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '$size • ${item.contentType.value}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha:0.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFullView(BuildContext context, String filename, IconData icon, String size) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GhostColors.surface.withValues(alpha:0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: GhostColors.primary.withValues(alpha:0.3),

        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: GhostColors.primary.withValues(alpha:0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 48,
              color: GhostColors.primary,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filename,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: Colors.white,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  size,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha:0.7),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.contentType.value.replaceAll('_', ' ').toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    color: GhostColors.primary.withValues(alpha:0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
