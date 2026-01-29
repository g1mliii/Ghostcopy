import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
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

  @override
  void dispose() {
    // CRITICAL: Dispose ui.Image to prevent native memory leak
    _decodedImage?.dispose();
    _decodedImage = null;
    
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
    final hasValidUrl = widget.item.content.isNotEmpty &&
        widget.item.content.startsWith('http');

    if (!hasValidUrl || _useFallback) {
      return _buildFallbackImage();
    }

    // Use CDN (fast path)
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: CachedNetworkImage(
        imageUrl: widget.item.content,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,

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
        memCacheWidth: widget.width != null ? (widget.width! * 2).toInt() : null,
        memCacheHeight: widget.height != null ? (widget.height! * 2).toInt() : null,

        // Disk cache configuration
        maxWidthDiskCache: 1000,
        maxHeightDiskCache: 1000,
      ),
    );
  }

  /// Build fallback image using direct storage download
  Widget _buildFallbackImage() {
    // If already loaded, decode in isolate and display
    if (_fallbackImageBytes != null) {
      return FutureBuilder<ui.Image>(
        future: _decodeImageInIsolate(_fallbackImageBytes!),
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
              debugPrint('[CachedClipboardImage] Image decode failed: ${snapshot.error}');
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

  /// Decode image in background isolate to prevent UI blocking
  Future<ui.Image> _decodeImageInIsolate(Uint8List bytes) async {
    // For small images (<100KB), decode on main thread to avoid isolate overhead
    if (bytes.length < 102400) {
      return _decodeImageSync(bytes);
    }

    // For large images, decode in background isolate
    return compute(_decodeImageIsolate, bytes);
  }

  /// Synchronous image decoding (for small images or in isolate)
  static Future<ui.Image> _decodeImageSync(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 1000, // Resize large images for performance
      targetHeight: 1000,
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
      debugPrint('[CachedClipboardImage] Loading from storage: ${widget.item.storagePath}');

      final bytes = await widget.clipboardRepository.downloadFile(widget.item);

      if (mounted) {
        if (bytes != null && bytes.isNotEmpty) {
          setState(() {
            _fallbackImageBytes = bytes;
            _isLoadingFallback = false;
          });
          debugPrint('[CachedClipboardImage] ✓ Loaded from storage (${bytes.length} bytes)');
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

/// Top-level function for image decoding in isolate
/// Must be top-level to work with compute()
Future<ui.Image> _decodeImageIsolate(Uint8List bytes) async {
  return _CachedClipboardImageState._decodeImageSync(bytes);
}
