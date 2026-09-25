import 'package:flutter/material.dart';

import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../viewmodels/mobile_main_viewmodel.dart';

/// Shown over the app while something shared into it is sent.
///
/// Sharing from another app opens GhostCopy and sends from there, so without
/// this the user looked at the splash or an idle list for a few seconds with
/// nothing saying a share was on its way. "Sent" goes by itself; a failure
/// stays, with its reason, until closed.
class ShareProgressOverlay extends StatelessWidget {
  const ShareProgressOverlay({
    required this.progress,
    required this.onClose,
    super.key,
  });

  final ShareProgress progress;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final sending = progress.stage == ShareProgressStage.sending;
    final failed = progress.stage == ShareProgressStage.failed;
    final title = switch (progress.stage) {
      ShareProgressStage.sending => 'Sending to ${progress.destination}',
      ShareProgressStage.sent => 'Sent to ${progress.destination}',
      ShareProgressStage.failed => 'Couldn’t send',
    };

    return Stack(
      children: [
        // Blocks the page while a send is under way; once it has settled, a
        // tap anywhere puts the overlay away.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: sending ? null : onClose,
            child: const ColoredBox(color: Color(0x99000000)),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(GhostSpacing.gutter * 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Semantics(
                liveRegion: true,
                child: Material(
                  color: GhostColors.surface,
                  borderRadius: BorderRadius.circular(
                    GhostSpacing.surfaceRadius,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        GhostSpacing.surfaceRadius,
                      ),
                      border: Border.all(color: GhostColors.border),
                    ),
                    padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 44,
                          child: Center(child: _buildMark(progress.stage)),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: GhostTypography.headline.copyWith(
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          progress.summary,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: GhostTypography.caption.copyWith(
                            color: failed
                                ? GhostColors.errorLight
                                : GhostColors.textMuted,
                          ),
                        ),
                        if (failed) ...[
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: onClose,
                            child: const Text('Close'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMark(ShareProgressStage stage) => switch (stage) {
    ShareProgressStage.sending => Adaptive.progressIndicator(
      size: 30,
      strokeWidth: 3,
      color: GhostColors.primary,
    ),
    ShareProgressStage.sent => const Icon(
      Icons.check_circle_rounded,
      size: 44,
      color: GhostColors.success,
    ),
    ShareProgressStage.failed => const Icon(
      Icons.error_outline_rounded,
      size: 44,
      color: GhostColors.error,
    ),
  };
}
