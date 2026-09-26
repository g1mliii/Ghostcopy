import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A JPEG of [args].$1 no larger than [args].$2 bytes, or null when the image
/// cannot be decoded or will not fit even at [photoMinSide] pixels.
///
/// Only for a photo that would otherwise be refused: anything that already
/// fits is sent untouched. The longest side starts at [photoMaxSide] - double what
/// image_picker used to cap every photo at - and halves until the JPEG fits.
/// Pure Dart and slow on a large photo, so run it through `compute`. One
/// record argument for that reason.
Uint8List? shrinkImageToFit((Uint8List, int) args) {
  final (bytes, maxBytes) = args;
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    // The decoder throws on some malformed input rather than returning null.
    return null;
  }
  if (decoded == null) return null;
  // Camera JPEGs store rotation as an EXIF flag; the re-encode drops EXIF.
  final image = img.bakeOrientation(decoded);
  var side = math.min(photoMaxSide, math.max(image.width, image.height));
  while (side >= photoMinSide) {
    final resized = image.width >= image.height
        ? img.copyResize(image, width: math.min(side, image.width))
        : img.copyResize(image, height: math.min(side, image.height));
    final jpeg = img.encodeJpg(resized, quality: photoJpegQuality);
    if (jpeg.length <= maxBytes) return jpeg;
    side ~/= 2;
  }
  return null;
}

// Shared with the native HEIC transcoders through IImageTranscoder, so a
// converted photo and a shrunk one come out alike.
const photoMaxSide = 4096;
const photoMinSide = 1024;
const photoJpegQuality = 85;
