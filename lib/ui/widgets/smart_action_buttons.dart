import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/transformer_service.dart';
import '../theme/colors.dart';
import 'ghost_toast.dart';

/// Smart action buttons that appear based on detected content type
///
/// Displays context-aware action buttons for:
/// - JSON: Prettify button
/// - JWT: Decode button
/// - Hex Color: Copy color button with preview square
///
/// Performance: Only renders when content type is detected
/// Requirements: 7.1, 7.2, 7.3, 7.4
class SmartActionButtons extends StatelessWidget {
  const SmartActionButtons({
    required this.content,
    required this.detectionResult,
    required this.transformerService,
    this.onTransform,
    super.key,
  });

  final String content;
  final ContentDetectionResult detectionResult;
  final ITransformerService transformerService;
  final VoidCallback? onTransform;

  @override
  Widget build(BuildContext context) {
    // Don't show buttons for plain text
    if (detectionResult.type == TransformerContentType.plainText) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _buildActionButtons(context),
      ),
    );
  }

  List<Widget> _buildActionButtons(BuildContext context) {
    switch (detectionResult.type) {
      case TransformerContentType.json:
        return [_buildPrettifyButton(context)];
      case TransformerContentType.jwt:
        return [_buildDecodeButton(context)];
      case TransformerContentType.hexColor:
        return [_buildCopyColorButton(context)];
      case TransformerContentType.plainText:
        return [];
    }
  }

  Widget _buildPrettifyButton(BuildContext context) {
    return _SmartActionButton(
      icon: Icons.code,
      label: 'Prettify JSON',
      color: GhostColors.primary,
      onTap: () => _handlePrettifyJson(context),
    );
  }

  Widget _buildDecodeButton(BuildContext context) {
    return _SmartActionButton(
      icon: Icons.lock_open,
      label: 'Decode JWT',
      color: GhostColors.warning,
      onTap: () => _handleDecodeJwt(context),
    );
  }

  Widget _buildCopyColorButton(BuildContext context) {
    final colorValue = detectionResult.metadata?['color'] as String?;
    // Parse color once and reuse for both button color and preview (performance optimization)
    final parsedColor = _parseHexColor(colorValue ?? '#000000');
    return _SmartActionButton(
      icon: Icons.palette,
      label: 'Copy Color',
      color: parsedColor,
      onTap: () => _handleCopyColor(context, colorValue ?? ''),
      leading: colorValue != null
          ? Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: parsedColor,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: GhostColors.glassBorder),
              ),
            )
          : null,
    );
  }

  Future<void> _handlePrettifyJson(BuildContext context) async {
    final result = await transformerService.transform(
      content,
      TransformerContentType.json,
    );

    if (result.error != null) {
      if (context.mounted) {
        showGhostToast(
          context,
          'Error: ${result.error}',
          type: GhostToastType.error,
        );
      }
      return;
    }

    if (result.transformedContent != null) {
      // Copy prettified JSON to clipboard
      await Clipboard.setData(ClipboardData(text: result.transformedContent!));

      if (context.mounted) {
        showGhostToast(
          context,
          'Prettified JSON copied to clipboard',
          icon: Icons.code,
          type: GhostToastType.success,
        );
      }

      onTransform?.call();
    }
  }

  Future<void> _handleDecodeJwt(BuildContext context) async {
    final result = await transformerService.transform(
      content,
      TransformerContentType.jwt,
    );

    if (result.error != null) {
      if (context.mounted) {
        showGhostToast(
          context,
          'Error: ${result.error}',
          type: GhostToastType.error,
        );
      }
      return;
    }

    if (result.preview != null) {
      // Show decoded JWT in a bottom sheet
      if (context.mounted) {
        _showJwtPreviewSheet(context, result.preview!);
      }
    }
  }

  void _showJwtPreviewSheet(BuildContext context, String preview) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: GhostColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: GhostColors.textMuted.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.lock_open, color: GhostColors.warning, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'JWT Token Decoded',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: GhostColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    color: GhostColors.textMuted,
                    iconSize: 20,
                  ),
                ],
              ),
            ),
            const Divider(color: GhostColors.glassBorder, height: 1),
            // Content
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: GhostColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: GhostColors.glassBorder),
                    ),
                    child: SelectableText(
                      preview,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 12,
                        color: GhostColors.textPrimary,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: preview));
                        Navigator.of(context).pop();
                        showGhostToast(
                          context,
                          'JWT payload copied to clipboard',
                          icon: Icons.copy,
                          type: GhostToastType.success,
                        );
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy Decoded Payload'),
                      style: FilledButton.styleFrom(
                        backgroundColor: GhostColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCopyColor(BuildContext context, String colorValue) async {
    await Clipboard.setData(ClipboardData(text: colorValue));

    if (context.mounted) {
      showGhostToast(
        context,
        'Color $colorValue copied',
        icon: Icons.palette,
        type: GhostToastType.success,
      );
    }
  }

  Color _parseHexColor(String hexString) {
    try {
      final buffer = StringBuffer();
      if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
      buffer.write(hexString.replaceFirst('#', ''));
      return Color(int.parse(buffer.toString(), radix: 16));
    } on Exception {
      return GhostColors.primary;
    }
  }
}

/// Individual smart action button widget
class _SmartActionButton extends StatelessWidget {
  const _SmartActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.leading,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
