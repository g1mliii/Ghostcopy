import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';

void main() {
  group('thumbnailTargetSize', () {
    // Capping only the width let a full-page screenshot through at 512x9481 -
    // a multi-megabyte "thumbnail" - and upscaled every small icon to 512.
    test('caps the longest edge of a tall image', () {
      final size = ClipboardRepository.thumbnailTargetSize(1080, 20000);
      expect(size.width, isNull);
      expect(size.height, 512);
    });

    test('caps the longest edge of a wide image', () {
      final size = ClipboardRepository.thumbnailTargetSize(6000, 400);
      expect(size.width, 512);
      expect(size.height, isNull);
    });

    test('never scales a small image up', () {
      final size = ClipboardRepository.thumbnailTargetSize(64, 64);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });

    test('leaves an image already at the limit alone', () {
      final size = ClipboardRepository.thumbnailTargetSize(512, 300);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });
  });
}
