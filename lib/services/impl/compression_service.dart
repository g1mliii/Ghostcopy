import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../compression_service.dart';

/// Implementation of image compression service
///
/// Uses the `image` package for decoding/encoding and `compute()` isolate
/// for images > 500KB to avoid UI jank.
class CompressionService implements ICompressionService {
  factory CompressionService() => instance;

  CompressionService._internal();

  static final CompressionService instance = CompressionService._internal();

  /// Threshold above which compression runs in a background isolate
  static const int _isolateThreshold = 512000; // 500KB

  @override
  Future<CompressionResult> compressImage(
    Uint8List bytes,
    String mimeType, {
    int maxDimension = 1920,
    int jpegQuality = 85,
  }) async {
    // GIF: pass through unchanged (preserve animation)
    if (mimeType == 'image/gif') {
      return CompressionResult(
        bytes: bytes,
        mimeType: mimeType,
        width: 0,
        height: 0,
        originalSize: bytes.length,
        compressedSize: bytes.length,
      );
    }

    final params = _CompressParams(
      bytes: bytes,
      mimeType: mimeType,
      maxDimension: maxDimension,
      jpegQuality: jpegQuality,
    );

    // Use isolate for large images to avoid UI jank
    if (bytes.length > _isolateThreshold) {
      debugPrint(
        '[CompressionService] Using isolate for ${bytes.length} byte image',
      );
      return compute(_compressInIsolate, params);
    }

    return _compress(params);
  }

  @override
  void dispose() {
    // No resources to dispose
  }
}

/// Parameters for compression (must be serializable for compute())
class _CompressParams {
  const _CompressParams({
    required this.bytes,
    required this.mimeType,
    required this.maxDimension,
    required this.jpegQuality,
  });

  final Uint8List bytes;
  final String mimeType;
  final int maxDimension;
  final int jpegQuality;
}

/// Top-level function for compute() isolate
CompressionResult _compressInIsolate(_CompressParams params) {
  return _compress(params);
}

/// Core compression logic
CompressionResult _compress(_CompressParams params) {
  final originalSize = params.bytes.length;

  // Decode image
  final image = img.decodeImage(params.bytes);
  if (image == null) {
    // Can't decode — return original
    return CompressionResult(
      bytes: params.bytes,
      mimeType: params.mimeType,
      width: 0,
      height: 0,
      originalSize: originalSize,
      compressedSize: originalSize,
    );
  }

  // Resize if any dimension exceeds maxDimension
  var processed = image;
  if (image.width > params.maxDimension ||
      image.height > params.maxDimension) {
    if (image.width >= image.height) {
      processed = img.copyResize(
        image,
        width: params.maxDimension,
        interpolation: img.Interpolation.linear,
      );
    } else {
      processed = img.copyResize(
        image,
        height: params.maxDimension,
        interpolation: img.Interpolation.linear,
      );
    }
  }

  // Encode based on mime type
  late Uint8List compressedBytes;
  late String outputMimeType;

  if (params.mimeType == 'image/png') {
    // PNG: keep as PNG (preserves transparency)
    compressedBytes = Uint8List.fromList(img.encodePng(processed));
    outputMimeType = 'image/png';
  } else {
    // JPEG (and anything else): encode as JPEG
    compressedBytes = Uint8List.fromList(
      img.encodeJpg(processed, quality: params.jpegQuality),
    );
    outputMimeType = 'image/jpeg';
  }

  // If compressed is larger or equal, return original
  if (compressedBytes.length >= originalSize) {
    return CompressionResult(
      bytes: params.bytes,
      mimeType: params.mimeType,
      width: image.width,
      height: image.height,
      originalSize: originalSize,
      compressedSize: originalSize,
    );
  }

  return CompressionResult(
    bytes: compressedBytes,
    mimeType: outputMimeType,
    width: processed.width,
    height: processed.height,
    originalSize: originalSize,
    compressedSize: compressedBytes.length,
  );
}
