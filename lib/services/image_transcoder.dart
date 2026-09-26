import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/image_shrink.dart';

/// Re-encodes photos the `image` package cannot decode - HEIC and HEIF, which
/// is what an iPhone camera saves by default - as JPEG, through the platform's
/// own decoder.
///
/// Sent as-is, a HEIC went as a plain file: no preview anywhere, unopenable on
/// most Windows machines, and refused outright over the size limit because
/// `shrinkImageToFit` could not read it. Converting on the way out is what iOS
/// itself does when a photo leaves for a non-Apple device.
// An interface rather than a function so the view model can take a fake.
// ignore: one_member_abstracts
abstract class IImageTranscoder {
  /// A JPEG of the image at [path] no larger than [maxBytes], or null when
  /// this platform cannot decode it or it will not fit.
  ///
  /// The longest side is capped at 4096px and halved until the JPEG fits, as
  /// `shrinkImageToFit` does. EXIF orientation is applied; the rest of the
  /// metadata, location included, is dropped.
  Future<Uint8List?> toJpeg(String path, {required int maxBytes});
}

/// Formats [IImageTranscoder] exists for, by file extension.
const heicExtensions = {'heic', 'heif'};

class ImageTranscoder implements IImageTranscoder {
  const ImageTranscoder();

  // Mirrors ImageTranscoder in ios/Runner/FlutterChannelHub.swift and
  // android/.../ImageTranscoder.kt.
  static const _channel = MethodChannel('com.ghostcopy/image_transcoder');

  @override
  Future<Uint8List?> toJpeg(String path, {required int maxBytes}) async {
    // Only the phones implement it; a Mac or PC sends the file as it is.
    if (!Platform.isIOS && !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('toJpeg', {
        'path': path,
        'maxBytes': maxBytes,
        'maxSide': photoMaxSide,
        'minSide': photoMinSide,
        'quality': photoJpegQuality,
      });
    } on PlatformException catch (e) {
      debugPrint('[ImageTranscoder] Could not convert: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
