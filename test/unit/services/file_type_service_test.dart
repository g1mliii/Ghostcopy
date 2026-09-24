import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/clipboard_item.dart';
import 'package:ghostcopy/services/file_type_service.dart';

void main() {
  for (final fixture in [
    ('heic', 'heic', 'image/heic', ContentType.fileOther),
    ('mif1', 'heif', 'image/heif', ContentType.fileOther),
    ('avif', 'avif', 'image/avif', ContentType.fileOther),
    ('isom', 'mp4', 'video/mp4', ContentType.fileMp4),
  ]) {
    test('ftyp brand ${fixture.$1} preserves its actual file format', () {
      final bytes = Uint8List.fromList([
        0,
        0,
        0,
        24,
        ...'ftyp'.codeUnits,
        ...fixture.$1.codeUnits,
      ]);
      final service = FileTypeService.instance;
      final fromBytes = service.detectFromBytes(bytes, null);
      final fromName = service.detectFromExtension('original.${fixture.$2}');
      for (final info in [fromBytes, fromName]) {
        expect(info.extension, fixture.$2);
        expect(info.mimeType, fixture.$3);
        expect(info.contentType, fixture.$4);
      }
    });
  }
}
