import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/clipboard_cache_manager.dart';
import '../../services/encryption_service.dart';
import '../../services/impl/encryption_service.dart';
import '../platform_adaptive.dart';
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
    this.encryptionService,
    super.key,
  });

  final ClipboardItem item;
  final IClipboardRepository clipboardRepository;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;

  /// Whose key decrypts the image; the app-wide service unless a test
  /// supplies one.
  final IEncryptionService? encryptionService;

  @override
  State<CachedClipboardImage> createState() => _CachedClipboardImageState();
}

class _CachedClipboardImageState extends State<CachedClipboardImage> {
  // Fixed for the widget's life: the listener is added to and removed from
  // this one service.
  late final IEncryptionService _encryption =
      widget.encryptionService ?? EncryptionService.instance;

  /// Whether this device holds a passphrase, so an encrypted image can be
  /// shown rather than reported as a load failure. Resolved asynchronously
  /// because build() cannot await, and re-resolved whenever the source or the
  /// service's loaded key changes.
  bool _canDecrypt = false;

  bool _useFallback = false;
  Uint8List? _fallbackImageBytes;
  bool _isLoadingFallback = false;
  int _loadGeneration = 0;

  /// Set once a storage load has failed for the current source.
  ///
  /// Without it the build path re-schedules [_loadFallbackImage] on every
  /// frame: clearing [_isLoadingFallback] on failure re-satisfies the same
  /// condition that started the load, so an undecryptable image or one
  /// transient 5xx spins forever, re-hitting storage-presign (rate-limited at
  /// 120/min) and starving every other image on screen. Cleared whenever the
  /// source changes so a genuinely new item still gets its own attempt.
  bool _fallbackFailed = false;
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

  /// Decode target in PHYSICAL pixels, which is what the decoder wants.
  ///
  /// cacheWidth/memCacheWidth are physical, not logical. Passing the logical
  /// size decoded a 52dp thumbnail at 52px and let the framework upscale it
  /// ~2.6x, which is why previews looked soft. Passing nothing at all is worse
  /// in the other direction: the image is then decoded at its natural size, so
  /// a photo off a phone camera costs tens of MB of image cache to fill a 52dp
  /// box - several of those in a history list is real memory.
  ///
  /// Clamped at 2x: beyond that the extra pixels are indistinguishable at
  /// thumbnail size and only cost memory.
  int? _decodePx(BuildContext context, double? value) {
    if (value == null || !value.isFinite || value <= 0) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    return (value * dpr).round();
  }

  @override
  void initState() {
    super.initState();
    // Re-resolve whenever the key changes. On a cold start this widget builds
    // before EncryptionService.initialize() has derived the key, so isEnabled()
    // answers false and, cached, would lock every encrypted image for the life
    // of the screen.
    _encryption.keyRevision.addListener(_onKeyRevisionChanged);
    if (widget.item.isEncrypted) {
      unawaited(_resolveCanDecrypt());
    }
  }

  void _onKeyRevisionChanged() {
    if (!widget.item.isEncrypted) return;
    // A new key may decrypt what the old one could not - the passphrase
    // entered after this thumbnail first failed. Without this, a failed
    // download stayed failed until the item was rebuilt with another source.
    if (_fallbackFailed && mounted) {
      setState(() {
        _loadGeneration++;
        _fallbackFailed = false;
        _isLoadingFallback = false;
      });
    }
    unawaited(_resolveCanDecrypt());
  }

  Future<void> _resolveCanDecrypt() async {
    final enabled = await _encryption.isEnabled();
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
      _loadGeneration++;
      _useFallback = false;
      _fallbackImageBytes = null;
      _isLoadingFallback = false;
      _fallbackFailed = false;
    }

    // Re-resolve on every encrypted source. A recycled State whose first item
    // was unencrypted never ran this in initState, so it kept _canDecrypt
    // false and showed the locked placeholder for an item it can in fact
    // decrypt.
    if (didSourceChange && widget.item.isEncrypted) {
      unawaited(_resolveCanDecrypt());
    }

    if (didSourceChange || didTargetSizeChange) {
      _resetDecodedImageState();
    }
  }

  @override
  void dispose() {
    _encryption.keyRevision.removeListener(_onKeyRevisionChanged);
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
      return _buildFallbackImage(context);
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
          child: Center(
            child: Adaptive.progressIndicator(color: GhostColors.primary),
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
            child: Center(
              child: Adaptive.progressIndicator(color: GhostColors.primary),
            ),
          );
        },

        // Decode bound to display size. The hardcoded 2x this replaces was a
        // stand-in for device pixel ratio; using the real one decodes less on
        // 1x displays and is still capped at 2x, where extra detail stops being
        // visible at thumbnail size. See _decodePx.
        memCacheWidth: _decodePx(context, widget.width),
        memCacheHeight: _decodePx(context, widget.height),

        // Disk cache configuration
        // maxWidthDiskCache: 1000, // Removed to prevent crash (ImageCacheManager required)
        // maxHeightDiskCache: 1000, // Removed to prevent crash (ImageCacheManager required)
      ),
    );
  }

  /// Build fallback image using direct storage download
  Widget _buildFallbackImage(BuildContext context) {
    // Decode asynchronously using the engine's image decoder.
    if (_fallbackImageBytes != null) {
      final decodeFuture = _getDecodeFuture(context, _fallbackImageBytes!);
      return FutureBuilder<ui.Image>(
        future: decodeFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (snapshot.hasData && snapshot.data != null) {
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

    // A previous attempt for this source failed. Stop here rather than
    // scheduling another download; retrying is what looped.
    if (_fallbackFailed) {
      return _buildErrorWidget('Failed to load image');
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
      child: Center(
        child: Adaptive.progressIndicator(color: GhostColors.primary),
      ),
    );
  }

  Future<ui.Image> _getDecodeFuture(BuildContext context, Uint8List bytes) {
    // Physical pixels, like the primary path. This decoded at the LOGICAL size,
    // so a 52dp thumbnail was decoded at 52px and then upscaled by the device
    // pixel ratio - the reason fallback previews looked softer than the ones
    // served through CachedNetworkImage.
    final targetW = _decodePx(context, widget.width);
    final targetH = _decodePx(context, widget.height);
    final decodeKey = Object.hash(bytes, targetW, targetH);

    if (_fallbackDecodeFuture == null || _fallbackDecodeKey != decodeKey) {
      _resetDecodedImageState();
      _fallbackDecodeKey = decodeKey;
      final generation = _decodeGeneration;
      _fallbackDecodeFuture =
          _decodeImage(bytes, targetWidth: targetW, targetHeight: targetH).then(
            (image) {
              if (!mounted || generation != _decodeGeneration) {
                image.dispose();
                throw Exception('Thumbnail decode superseded');
              }
              _decodedImage = image;
              return image;
            },
          );
    }

    return _fallbackDecodeFuture!;
  }

  int _decodeGeneration = 0;

  void _resetDecodedImageState() {
    _decodeGeneration++;
    _fallbackDecodeFuture = null;
    _fallbackDecodeKey = null;
    _decodedImage?.dispose();
    _decodedImage = null;
  }

  /// The engine decodes asynchronously; ui.Image cannot cross isolate boundaries.
  static Future<ui.Image> _decodeImage(
    Uint8List bytes, {
    int? targetWidth,
    int? targetHeight,
  }) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// Load image from storage (fallback method)
  Future<void> _loadFallbackImage() async {
    if (_isLoadingFallback || _fallbackImageBytes != null || _fallbackFailed) {
      return;
    }

    // Plain assignment, not setState: the caller already renders the loading
    // indicator for this state, so no rebuild is needed, and this method can be
    // reached from a build-adjacent path where setState would be illegal.
    _isLoadingFallback = true;
    final generation = _loadGeneration;

    try {
      debugPrint(
        '[CachedClipboardImage] Loading from storage: ${widget.item.storagePath}',
      );

      final bytes = await widget.clipboardRepository.downloadFile(widget.item);

      if (mounted && generation == _loadGeneration) {
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
            _fallbackFailed = true;
          });
          debugPrint('[CachedClipboardImage] ✗ Failed to load from storage');
        }
      }
    } on Exception catch (e) {
      debugPrint('[CachedClipboardImage] ✗ Error loading from storage: $e');
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _isLoadingFallback = false;
          _fallbackFailed = true;
        });
      }
    }
  }

  /// Build error widget
  /// Shown for an encrypted image this device holds no passphrase for.
  /// True when this instance is rendering a list thumbnail rather than a
  /// full-width preview.
  ///
  /// The placeholders below pair an icon with a sentence, which fits a
  /// full-width preview and overflows a 52px thumbnail by more than its own
  /// height. At thumbnail size the icon alone has to carry the meaning.
  bool get _isCompact {
    final height = widget.height;
    return height != null && height < 96;
  }

  Widget _buildLockedWidget() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(color: GhostColors.primary.withValues(alpha: 0.4)),
      ),
      child: _isCompact
          ? const Center(
              child: Icon(
                Icons.lock_outline,
                color: GhostColors.primary,
                size: 20,
              ),
            )
          : Column(
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
      child: _isCompact
          ? Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: GhostColors.textMutedAlpha50,
                size: 20,
              ),
            )
          : Column(
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
                  textAlign: TextAlign.center,
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
