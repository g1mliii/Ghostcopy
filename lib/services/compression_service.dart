import 'dart:typed_data';

export 'impl/compression_service.dart';

/// Result of image compression
class CompressionResult {
  const CompressionResult({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.originalSize,
    required this.compressedSize,
  });

  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;
  final int originalSize;
  final int compressedSize;

  double get compressionRatio =>
      originalSize > 0 ? compressedSize / originalSize : 1.0;

  bool get wasCompressed => compressedSize < originalSize;
}

/// Abstract interface for image compression
abstract class ICompressionService {
  /// Compress an image, resizing if larger than [maxDimension] and
  /// re-encoding at [jpegQuality] for JPEGs.
  ///
  /// - PNG: resize only (preserves transparency)
  /// - JPEG: resize + re-encode at quality
  /// - GIF: pass through unchanged (preserve animation)
  /// - If compressed >= original, returns original bytes
  Future<CompressionResult> compressImage(
    Uint8List bytes,
    String mimeType, {
    int maxDimension = 1920,
    int jpegQuality = 85,
  });

  /// Dispose resources
  void dispose();
}
