import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/image_shrink.dart';
import 'package:image/image.dart' as img;

void main() {
  // Noise, so the JPEG size tracks the pixel count rather than compressing to
  // nothing.
  img.Image photo(int width, int height) {
    final random = Random(1);
    final image = img.Image(width: width, height: height);
    for (final pixel in image) {
      pixel
        ..r = random.nextInt(256)
        ..g = random.nextInt(256)
        ..b = random.nextInt(256);
    }
    return image;
  }

  test('a photo too big to send is scaled until it fits', () {
    final original = photo(2400, 1600);
    final full = img.encodeJpg(original, quality: 85);
    final png = img.encodePng(original);

    final shrunk = shrinkImageToFit((png, full.length - 1));

    expect(shrunk, isNotNull);
    expect(shrunk!.length, lessThan(full.length));
    final decoded = img.decodeJpg(shrunk)!;
    // Halved once, aspect ratio kept.
    expect(decoded.width, 1200);
    expect(decoded.height, 800);
  });

  test('a portrait photo is scaled by its height', () {
    final original = photo(1600, 2400);
    final full = img.encodeJpg(original, quality: 85);

    final shrunk = shrinkImageToFit((img.encodePng(original), full.length - 1));

    final decoded = img.decodeJpg(shrunk!)!;
    expect(decoded.height, 1200);
    expect(decoded.width, 800);
  });

  test('bytes that are not an image give null', () {
    expect(shrinkImageToFit((Uint8List.fromList([1, 2, 3]), 10)), isNull);
  });

  test('null when it cannot fit even at the smallest size', () {
    expect(shrinkImageToFit((img.encodePng(photo(2048, 1024)), 100)), isNull);
  });
}
