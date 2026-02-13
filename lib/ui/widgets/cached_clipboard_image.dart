import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/clipboard_cache_manager.dart';
import '../theme/colors.dart';

/// Smart image widget that uses CDN for fast loading with API fallback
///
/// Performance optimization:
/// 1. Tries to load from CDN URL (Cloudflare-backed, fast)
/// 2. Falls back to direct download if CDN fails
/// 3. Caches images on disk for offline access
/// 4. Handles loading/error states gracefully
///
/// Usage:
/// ```dart
/// CachedClipboardImage(
///   item: clipboardItem,
///   clipboardRepository: repository,
///   width: 200,
///   height: 150,
/// )
/// ```
class CachedClipboardImage extends StatefulWidget {
  const CachedClipboardImage({
    required this.item,
    required this.clipboardRepository,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 8.0,
    super.key,
  });

  final ClipboardItem item;
  final IClipboardRepository clipboardRepository;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;

  @override
  State<CachedClipboardImage> createState() => _CachedClipboardImageState();
}

class _CachedClipboardImageState extends State<CachedClipboardImage> {
  bool _useFallback = false;
  Uint8List? _fallbackImageBytes;
  bool _isLoadingFallback = false;
  ui.Image? _decodedImage; // Track decoded image for disposal
  Future<ui.Image>? _fallbackDecodeFuture;
  int? _fallbackDecodeKey;

  @override
  void didUpdateWidget(covariant CachedClipboardImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final didSourceChange =
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.content != widget.item.content ||
        oldWidget.item.storagePath != widget.item.storagePath;
    final didTargetSizeChange =
        oldWidget.width?.toInt() != widget.width?.toInt() ||
        oldWidget.height?.toInt() != widget.height?.toInt();

    if (didSourceChange) {
      _useFallback = false;
      _fallbackImageBytes = null;
      _isLoadingFallback = false;
    }

    if (didSourceChange || didTargetSizeChange) {
      _resetDecodedImageState();
    }
  }

  @override
  void dispose() {
    _resetDecodedImageState();

    // Clear fallback image bytes
    _fallbackImageBytes = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Validate that item is an image
    if (!widget.item.isImage) {
      return _buildErrorWidget('Not an image');
    }

    // Check if we have a valid URL for CDN
    final hasValidUrl =
        widget.item.content.isNotEmpty &&
        widget.item.content.startsWith('http');

    if (!hasValidUrl || _useFallback) {
      return _buildFallbackImage();
    }

    // Use CDN (fast path) with custom cache manager
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: CachedNetworkImage(
        imageUrl: widget.item.content,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheManager: ClipboardCacheManager.instance.cacheManager,

        // Loading indicator
        placeholder: (context, url) => Container(
          width: widget.width,
          height: widget.height,
          color: GhostColors.surface,
          child: const Center(
            child: CircularProgressIndicator(
              color: GhostColors.primary,
              strokeWidth: 2,
            ),
          ),
        ),

        // Error handler with automatic fallback
        errorWidget: (context, url, error) {
          debugPrint('[CachedClipboardImage] CDN load failed: $error');
          debugPrint('[CachedClipboardImage] Falling back to API download');

          // Trigger fallback to download from storage
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _useFallback = true;
              });
            }
          });

          // Show loading state while waiting for fallback
          return Container(
            width: widget.width,
            height: widget.height,
            color: GhostColors.surface,
            child: const Center(
              child: CircularProgressIndicator(
                color: GhostColors.primary,
                strokeWidth: 2,
              ),
            ),
          );
        },

        // Memory cache configuration
        memCacheWidth: (widget.width?.isFinite ?? false)
            ? (widget.width! * 2).toInt()
            : null,
        memCacheHeight: (widget.height?.isFinite ?? false)
            ? (widget.height! * 2).toInt()
            : null,

        // Disk cache configuration
        // maxWidthDiskCache: 1000, // Removed to prevent crash (ImageCacheManager required)
        // maxHeightDiskCache: 1000, // Removed to prevent crash (ImageCacheManager required)
      ),
    );
  }

  /// Build fallback image using direct storage download
  Widget _buildFallbackImage() {
    // If already loaded, decode in isolate and display
    if (_fallbackImageBytes != null) {
      final decodeFuture = _getDecodeFuture(_fallbackImageBytes!);
      return FutureBuilder<ui.Image>(
        future: decodeFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasData && snapshot.data != null) {
              // Dispose previous image before storing new one
              if (_decodedImage != snapshot.data) {
                _decodedImage?.dispose();
                _decodedImage = snapshot.data;
              }

              return ClipRRect(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                child: RawImage(
                  image: snapshot.data,
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                ),
              );
            } else if (snapshot.hasError) {
              debugPrint(
                '[CachedClipboardImage] Image decode failed: ${snapshot.error}',
              );
              return _buildErrorWidget('Failed to decode image');
            }
          }
          // Loading
          return _buildLoadingIndicator();
        },
      );
    }

    // If loading, show progress
    if (_isLoadingFallback) {
      return _buildLoadingIndicator();
    }

    // Start loading
    _loadFallbackImage();

    return _buildLoadingIndicator();
  }

  /// Build loading indicator widget
  Widget _buildLoadingIndicator() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: const Center(
        child: CircularProgressIndicator(
          color: GhostColors.primary,
          strokeWidth: 2,
        ),
      ),
    );
  }

  Future<ui.Image> _getDecodeFuture(Uint8List bytes) {
    final decodeKey = Object.hash(
      bytes,
      widget.width?.toInt(),
      widget.height?.toInt(),
    );

    if (_fallbackDecodeFuture == null || _fallbackDecodeKey != decodeKey) {
      _fallbackDecodeKey = decodeKey;
      _fallbackDecodeFuture = _decodeImageInIsolate(
        bytes,
        targetWidth: widget.width?.toInt(),
        targetHeight: widget.height?.toInt(),
      );
    }

    return _fallbackDecodeFuture!;
  }

  void _resetDecodedImageState() {
    _fallbackDecodeFuture = null;
    _fallbackDecodeKey = null;
    _decodedImage?.dispose();
    _decodedImage = null;
  }

  /// Decode image in background isolate to prevent UI blocking
  Future<ui.Image> _decodeImageInIsolate(
    Uint8List bytes, {
    int? targetWidth,
    int? targetHeight,
  }) async {
    // For small images (<100KB), decode on main thread to avoid isolate overhead
    if (bytes.length < 102400) {
      return _decodeImageSync(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
    }

    // FIXED: compute() cannot return ui.Image (native handle), it will crash!
    // Use async main-thread decoding instead (instantiateImageCodec is already non-blocking)
    return _decodeImageSync(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
  }

  /// Synchronous image decoding (for small images or in isolate)
  static Future<ui.Image> _decodeImageSync(
    Uint8List bytes, {
    int? targetWidth,
    int? targetHeight,
  }) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Load image from storage (fallback method)
  Future<void> _loadFallbackImage() async {
    if (_isLoadingFallback) return;

    setState(() {
      _isLoadingFallback = true;
    });

    try {
      debugPrint(
        '[CachedClipboardImage] Loading from storage: ${widget.item.storagePath}',
      );

      final bytes = await widget.clipboardRepository.downloadFile(widget.item);

      if (mounted) {
        if (bytes != null && bytes.isNotEmpty) {
          _resetDecodedImageState();
          setState(() {
            _fallbackImageBytes = bytes;
            _isLoadingFallback = false;
          });
          debugPrint(
            '[CachedClipboardImage] ✓ Loaded from storage (${bytes.length} bytes)',
          );
        } else {
          setState(() {
            _isLoadingFallback = false;
          });
          debugPrint('[CachedClipboardImage] ✗ Failed to load from storage');
        }
      }
    } on Exception catch (e) {
      debugPrint('[CachedClipboardImage] ✗ Error loading from storage: $e');
      if (mounted) {
        setState(() {
          _isLoadingFallback = false;
        });
      }
    }
  }

  /// Build error widget
  Widget _buildErrorWidget(String message) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: GhostColors.textMuted.withValues(alpha: 0.5),
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              color: GhostColors.textMuted.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
