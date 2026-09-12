import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/clipboard_cache_manager.dart';
import '../../services/impl/encryption_service.dart';
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
  /// Whether this device holds a passphrase, so an encrypted image can be
  /// shown rather than reported as a load failure. Resolved once in initState
  /// because build() cannot await.
  bool _canDecrypt = false;

  bool _useFallback = false;
  Uint8List? _fallbackImageBytes;
  bool _isLoadingFallback = false;
  ui.Image? _decodedImage; // Track decoded image for disposal
  Future<ui.Image>? _fallbackDecodeFuture;
  int? _fallbackDecodeKey;

  /// Convert a layout dimension to a decode dimension.
  ///
  /// Callers legitimately pass `double.infinity` (the desktop history tile uses
  /// `width: double.infinity` to fill its row). `infinity.toInt()` throws
  /// "Unsupported operation: Infinity", which surfaced as a broken preview on
  /// every image. NaN and non-positive values are equally unusable as decode
  /// targets, so all of them mean "decode at natural size".
  int? _decodeDimension(double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    return value.toInt();
  }

  @override
  void initState() {
    super.initState();
    if (widget.item.isEncrypted) {
      unawaited(_resolveCanDecrypt());
    }
  }

  Future<void> _resolveCanDecrypt() async {
    final enabled = await EncryptionService.instance.isEnabled();
    if (mounted && enabled != _canDecrypt) {
      setState(() => _canDecrypt = enabled);
    }
  }

  @override
  void didUpdateWidget(covariant CachedClipboardImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final didSourceChange =
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.content != widget.item.content ||
        oldWidget.item.storagePath != widget.item.storagePath;
    final didTargetSizeChange =
        _decodeDimension(oldWidget.width) != _decodeDimension(widget.width) ||
        _decodeDimension(oldWidget.height) != _decodeDimension(widget.height);

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

    // An encrypted image on a device without the passphrase is not an error -
    // the bytes are fine, this device just cannot read them. downloadFile
    // returns null in that case, which would otherwise render as a generic
    // "Failed to load" and look like a bug.
    if (widget.item.isEncrypted && !_canDecrypt) {
      return _buildLockedWidget();
    }

    // The R2 bucket is PRIVATE. `content` holds a public r2.dev URL written
    // when it was public, and that now returns 401 for every object - so the
    // CDN path cannot succeed and would just burn a failed request before
    // falling back. Whenever the row has a storage_path, go straight to the
    // signed-URL download instead.
    final hasStoragePath = (widget.item.storagePath ?? '').isNotEmpty;

    final hasValidUrl =
        !hasStoragePath &&
        widget.item.content.isNotEmpty &&
        widget.item.content.startsWith('http');

    if (!hasValidUrl || _useFallback) {
      return _buildFallbackImage();
    }

    // Use CDN (fast path) with custom cache manager
    // Perf: Use Container with decoration instead of ClipRRect to avoid
    // saveLayer on raster thread. clipBehavior on the Container achieves
    // the same visual clipping without the GPU overhead.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      clipBehavior: Clip.antiAlias,
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

              // Perf: Container with clipBehavior instead of ClipRRect
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                ),
                clipBehavior: Clip.antiAlias,
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

    // Start loading after this frame. Calling it directly from build() reached
    // a synchronous setState() inside _loadFallbackImage (it runs before the
    // first await), triggering "setState() called during build".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadFallbackImage());
    });

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
      _decodeDimension(widget.width),
      _decodeDimension(widget.height),
    );

    if (_fallbackDecodeFuture == null || _fallbackDecodeKey != decodeKey) {
      _fallbackDecodeKey = decodeKey;
      _fallbackDecodeFuture = _decodeImageInIsolate(
        bytes,
        targetWidth: _decodeDimension(widget.width),
        targetHeight: _decodeDimension(widget.height),
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

    // Plain assignment, not setState: the caller already renders the loading
    // indicator for this state, so no rebuild is needed, and this method can be
    // reached from a build-adjacent path where setState would be illegal.
    _isLoadingFallback = true;

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
  /// Shown for an encrypted image this device holds no passphrase for.
  Widget _buildLockedWidget() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(color: GhostColors.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.lock_outline,
            color: GhostColors.primary,
            size: 28,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Encrypted - add your passphrase in Settings to view',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: GhostColors.textMutedAlpha70,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
            color: GhostColors.textMutedAlpha50,
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              color: GhostColors.textMutedAlpha70,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
