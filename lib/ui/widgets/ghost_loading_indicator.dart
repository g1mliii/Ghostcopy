import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// Ghostcopy's activity mark for an indeterminate wait.
///
/// Use [label] for standalone states and [compact] next to an existing label.
class GhostLoadingIndicator extends StatelessWidget {
  const GhostLoadingIndicator({
    this.label,
    this.color = GhostColors.primary,
    this.size = 28,
    super.key,
  }) : _rows = 3;

  const GhostLoadingIndicator.compact({
    this.color = GhostColors.primary,
    this.size = 18,
    super.key,
  }) : label = null,
       _rows = 1;

  final String? label;
  final Color color;
  final double size;
  final int _rows;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: size,
      height: size,
      child: RepaintBoundary(
        child:
            MediaQuery.disableAnimationsOf(context) ||
                !TickerMode.valuesOf(context).enabled
            ? CustomPaint(
                painter: _LoadingPainter(
                  phase: const AlwaysStoppedAnimation(0.5),
                  color: color,
                  rows: _rows,
                ),
              )
            : _AnimatedLoadingMark(color: color, rows: _rows),
      ),
    );

    return label == null
        ? mark
        : Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                const SizedBox(height: 10),
                Text(
                  label!,
                  textAlign: TextAlign.center,
                  style: GhostTypography.caption.copyWith(
                    color: GhostColors.textMuted,
                  ),
                ),
              ],
            ),
          );
  }
}

class _AnimatedLoadingMark extends StatefulWidget {
  const _AnimatedLoadingMark({required this.color, required this.rows});

  final Color color;
  final int rows;

  @override
  State<_AnimatedLoadingMark> createState() => _AnimatedLoadingMarkState();
}

class _AnimatedLoadingMarkState extends State<_AnimatedLoadingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _LoadingPainter(
      phase: _phase,
      color: widget.color,
      rows: widget.rows,
    ),
  );
}

class _LoadingPainter extends CustomPainter {
  _LoadingPainter({
    required this.phase,
    required this.color,
    required this.rows,
  }) : super(repaint: phase);

  final Animation<double> phase;
  final Color color;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    const columns = 3;
    final step = size.width / columns;
    final cell = step * 0.72;
    final origin = Offset(
      (step - cell) / 2,
      (size.height - (rows - 1) * step - cell) / 2,
    );
    final radius = Radius.circular(rows == 1 ? cell / 2 : cell * 0.22);
    final paint = Paint();
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final wave = math.cos(
          (phase.value - (row + column) * 0.15) * 2 * math.pi,
        );
        paint.color = color.withValues(alpha: 0.6 + 0.4 * wave);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            (origin + Offset(column * step, row * step)) & Size.square(cell),
            radius,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LoadingPainter oldDelegate) =>
      phase != oldDelegate.phase ||
      color != oldDelegate.color ||
      rows != oldDelegate.rows;
}
