import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A JPEG of [args].$1 no larger than [args].$2 bytes, or null when the image
/// cannot be decoded or will not fit even at [_minSide] pixels.
///
/// Only for a photo that would otherwise be refused: anything that already
/// fits is sent untouched. The longest side starts at [_maxSide] - double what
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
  var side = math.min(_maxSide, math.max(image.width, image.height));
  while (side >= _minSide) {
    final resized = image.width >= image.height
        ? img.copyResize(image, width: math.min(side, image.width))
        : img.copyResize(image, height: math.min(side, image.height));
    final jpeg = img.encodeJpg(resized, quality: 85);
    if (jpeg.length <= maxBytes) return jpeg;
    side ~/= 2;
  }
  return null;
}

const _maxSide = 4096;
const _minSide = 1024;
