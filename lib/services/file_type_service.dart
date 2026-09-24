import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/clipboard_item.dart';

/// Information about a detected file type
class FileTypeInfo {
  const FileTypeInfo({
    required this.contentType,
    required this.mimeType,
    required this.extension,
  });

  final ContentType contentType;
  final String mimeType;
  final String extension;

  @override
  String toString() =>
      'FileTypeInfo(contentType: ${contentType.value}, mimeType: $mimeType, extension: $extension)';
}

/// Implementation of file type detection service
class FileTypeService {
  FileTypeService._();

  /// Singleton instance
  static final FileTypeService instance = FileTypeService._();

  // Cache for detection results, keyed by filename + size + signature bytes
  final Map<String, FileTypeInfo> _detectionCache = {};
  static const int _maxCacheSize = 100;

  /// The detected type, plus a filename that carries an extension.
  ///
  /// The extension is what identifies the content downstream: a name with
  /// nothing after the dot leaves a share sheet with no way to tell what it
  /// has, so it draws the icon of whatever handles unknown data - which is how
  /// a PDF came to arrive under Safari's logo. `originalFilename` is trusted
  /// when present, and otherwise the name is built from the sniffed extension.
  ///
  /// One copy of that policy. It was written out at four call sites across the
  /// mobile and desktop ViewModels, and had already drifted - the desktop copy
  /// never grew the `image.*` case - which is the same way the bug above got
  /// fixed on the notification path and left alone on the in-app one.
  ({String name, FileTypeInfo info}) resolveFilename(
    Uint8List bytes, {
    String? originalFilename,
    bool isImage = false,
  }) {
    final info = detectFromBytes(bytes, originalFilename);
    return (
      name:
          originalFilename ?? '${isImage ? 'image' : 'file'}.${info.extension}',
      info: info,
    );
  }

  FileTypeInfo detectFromBytes(Uint8List bytes, String? filename) {
    final cacheKey = _cacheKey(bytes, filename);

    // Check cache first
    if (_detectionCache.containsKey(cacheKey)) {
      return _detectionCache[cacheKey]!;
    }

    // Try magic bytes detection first (most reliable)
    final magicResult = _detectFromMagicBytes(bytes);
    if (magicResult != null) {
      // ...except where the signature is shared by several formats. A .docx is
      // a ZIP container, so magic bytes alone reported every Word document as
      // application/zip and the receiving device saved it as .zip, which will
      // not open. (Other OOXML types have no ContentType member yet, so they
      // still land on fileZip - add them here alongside the enum.)
      final refined = _refineAmbiguousType(magicResult, filename);
      _cacheResult(cacheKey, refined);
      return refined;
    }

    // Fallback to extension-based detection
    if (filename != null && filename.contains('.')) {
      final extensionResult = detectFromExtension(filename);
      _cacheResult(cacheKey, extensionResult);
      return extensionResult;
    }

    // Ultimate fallback
    const fallbackResult = FileTypeInfo(
      contentType: ContentType.fileOther,
      mimeType: 'application/octet-stream',
      extension: 'bin',
    );
    _cacheResult(cacheKey, fallbackResult);
    return fallbackResult;
  }

  /// Key identifying a detection input.
  ///
  /// Length and filename alone are not enough: the clipboard-image path passes
  /// a null filename, so every unnamed file of the same length collided and the
  /// second one was answered with the first one's type. The signature bytes are
  /// what detection actually reads, so they belong in the key.
  String _cacheKey(Uint8List bytes, String? filename) {
    final prefix = bytes.take(_signatureLength).join(',');
    return '${filename ?? ''}_${bytes.length}_$prefix';
  }

  /// Bytes the longest magic-byte check inspects (WAV reads through byte 11).
  static const int _signatureLength = 12;

  /// Prefer the extension when the magic bytes cannot tell formats apart.
  ///
  /// Only applied to container signatures where the extension carries strictly
  /// more information than the bytes. Everything else keeps the magic-byte
  /// answer, which stays authoritative against a misleading extension.
  FileTypeInfo _refineAmbiguousType(FileTypeInfo detected, String? filename) {
    if (detected.contentType != ContentType.fileZip) return detected;
    if (filename == null || !filename.contains('.')) return detected;

    final byExtension = detectFromExtension(filename);

    // Only upgrade to another ZIP-based format; a .txt extension on ZIP bytes
    // is a lie worth ignoring.
    const zipBased = {ContentType.fileDocx};
    if (zipBased.contains(byExtension.contentType)) return byExtension;

    return detected;
  }

  /// Cache the detection result with LRU eviction
  void _cacheResult(String key, FileTypeInfo result) {
    // Evict oldest entry if cache is full (simple FIFO)
    if (_detectionCache.length >= _maxCacheSize) {
      final firstKey = _detectionCache.keys.first;
      _detectionCache.remove(firstKey);
    }
    _detectionCache[key] = result;
  }

  FileTypeInfo detectFromExtension(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    final originalImage = _originalImageType(extension);
    if (originalImage != null) return originalImage;

    // Image types
    if (extension == 'png') {
      return const FileTypeInfo(
        contentType: ContentType.imagePng,
        mimeType: 'image/png',
        extension: 'png',
      );
    }
    if (extension == 'jpg' || extension == 'jpeg') {
      return const FileTypeInfo(
        contentType: ContentType.imageJpeg,
        mimeType: 'image/jpeg',
        extension: 'jpg',
      );
    }
    if (extension == 'gif') {
      return const FileTypeInfo(
        contentType: ContentType.imageGif,
        mimeType: 'image/gif',
        extension: 'gif',
      );
    }

    // Document types
    if (extension == 'pdf') {
      return const FileTypeInfo(
        contentType: ContentType.filePdf,
        mimeType: 'application/pdf',
        extension: 'pdf',
      );
    }
    if (extension == 'doc') {
      return const FileTypeInfo(
        contentType: ContentType.fileDoc,
        mimeType: 'application/msword',
        extension: 'doc',
      );
    }
    if (extension == 'docx') {
      return const FileTypeInfo(
        contentType: ContentType.fileDocx,
        mimeType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        extension: 'docx',
      );
    }
    if (extension == 'txt') {
      return const FileTypeInfo(
        contentType: ContentType.fileTxt,
        mimeType: 'text/plain',
        extension: 'txt',
      );
    }

    // Archive types
    if (extension == 'zip') {
      return const FileTypeInfo(
        contentType: ContentType.fileZip,
        mimeType: 'application/zip',
        extension: 'zip',
      );
    }
    if (extension == 'tar') {
      return const FileTypeInfo(
        contentType: ContentType.fileTar,
        mimeType: 'application/x-tar',
        extension: 'tar',
      );
    }
    if (extension == 'gz') {
      return const FileTypeInfo(
        contentType: ContentType.fileGz,
        mimeType: 'application/gzip',
        extension: 'gz',
      );
    }

    // Media types
    if (extension == 'mp4') {
      return const FileTypeInfo(
        contentType: ContentType.fileMp4,
        mimeType: 'video/mp4',
        extension: 'mp4',
      );
    }
    if (extension == 'mp3') {
      return const FileTypeInfo(
        contentType: ContentType.fileMp3,
        mimeType: 'audio/mpeg',
        extension: 'mp3',
      );
    }
    if (extension == 'wav') {
      return const FileTypeInfo(
        contentType: ContentType.fileWav,
        mimeType: 'audio/wav',
        extension: 'wav',
      );
    }

    // Default fallback
    return const FileTypeInfo(
      contentType: ContentType.fileOther,
      mimeType: 'application/octet-stream',
      extension: 'bin',
    );
  }

  IconData getFileIcon(ContentType type) {
    switch (type) {
      // Images
      case ContentType.imagePng:
      case ContentType.imageJpeg:
      case ContentType.imageGif:
        return Icons.image;

      // Documents
      case ContentType.filePdf:
        return Icons.picture_as_pdf;
      case ContentType.fileDoc:
      case ContentType.fileDocx:
        return Icons.description;
      case ContentType.fileTxt:
        return Icons.text_snippet;

      // Archives
      case ContentType.fileZip:
      case ContentType.fileTar:
      case ContentType.fileGz:
        return Icons.folder_zip;

      // Media
      case ContentType.fileMp4:
        return Icons.video_file;
      case ContentType.fileMp3:
      case ContentType.fileWav:
        return Icons.audio_file;

      // Rich text
      case ContentType.html:
      case ContentType.markdown:
        return Icons.code;

      // Default
      default:
        return Icons.insert_drive_file;
    }
  }

  /// Detect file type from magic bytes (file signatures)
  FileTypeInfo? _detectFromMagicBytes(Uint8List bytes) {
    if (bytes.length < 4) return null;

    // PNG: 89 50 4E 47 (‰PNG)
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return const FileTypeInfo(
        contentType: ContentType.imagePng,
        mimeType: 'image/png',
        extension: 'png',
      );
    }

    // JPEG: FF D8 FF
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return const FileTypeInfo(
        contentType: ContentType.imageJpeg,
        mimeType: 'image/jpeg',
        extension: 'jpg',
      );
    }

    // GIF: 47 49 46 38 (GIF8)
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return const FileTypeInfo(
        contentType: ContentType.imageGif,
        mimeType: 'image/gif',
        extension: 'gif',
      );
    }

    // PDF: 25 50 44 46 (%PDF)
    if (bytes.length >= 4 &&
        bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46) {
      return const FileTypeInfo(
        contentType: ContentType.filePdf,
        mimeType: 'application/pdf',
        extension: 'pdf',
      );
    }

    // ZIP (and DOCX, which is ZIP-based): 50 4B 03 04 or 50 4B 05 06 (PK)
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06)) {
      // Try to detect DOCX by checking for specific ZIP content
      // For now, default to ZIP (caller can override with filename)
      return const FileTypeInfo(
        contentType: ContentType.fileZip,
        mimeType: 'application/zip',
        extension: 'zip',
      );
    }

    // GZIP: 1F 8B
    if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      return const FileTypeInfo(
        contentType: ContentType.fileGz,
        mimeType: 'application/gzip',
        extension: 'gz',
      );
    }

    // ISO base-media containers share "ftyp". Preserve still-image formats
    // as files instead of incorrectly labelling HEIC/HEIF/AVIF as MP4 video.
    if (bytes.length >= 8 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      if (bytes.length >= 12) {
        final brand = String.fromCharCodes(bytes.sublist(8, 12));
        final extension = switch (brand) {
          'heic' || 'heix' || 'hevc' || 'hevx' => 'heic',
          'mif1' || 'msf1' => 'heif',
          'avif' || 'avis' => 'avif',
          _ => '',
        };
        final originalImage = _originalImageType(extension);
        if (originalImage != null) return originalImage;
      }
      return const FileTypeInfo(
        contentType: ContentType.fileMp4,
        mimeType: 'video/mp4',
        extension: 'mp4',
      );
    }

    // MP3: FF FB or FF F3 or ID3
    if (bytes.length >= 3) {
      if ((bytes[0] == 0xFF && (bytes[1] == 0xFB || bytes[1] == 0xF3)) ||
          (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33)) {
        return const FileTypeInfo(
          contentType: ContentType.fileMp3,
          mimeType: 'audio/mpeg',
          extension: 'mp3',
        );
      }
    }

    // WAV: RIFF....WAVE
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45) {
      return const FileTypeInfo(
        contentType: ContentType.fileWav,
        mimeType: 'audio/wav',
        extension: 'wav',
      );
    }

    // DOC: D0 CF 11 E0 A1 B1 1A E1 (OLE2 format)
    if (bytes.length >= 8 &&
        bytes[0] == 0xD0 &&
        bytes[1] == 0xCF &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xE0 &&
        bytes[4] == 0xA1 &&
        bytes[5] == 0xB1 &&
        bytes[6] == 0x1A &&
        bytes[7] == 0xE1) {
      return const FileTypeInfo(
        contentType: ContentType.fileDoc,
        mimeType: 'application/msword',
        extension: 'doc',
      );
    }

    return null;
  }

  /// These assets have no portable thumbnail renderer, but can be transferred
  /// unchanged using the generic file path and their actual MIME/extension.
  FileTypeInfo? _originalImageType(String extension) {
    if (extension != 'heic' && extension != 'heif' && extension != 'avif') {
      return null;
    }
    return FileTypeInfo(
      contentType: ContentType.fileOther,
      mimeType: 'image/$extension',
      extension: extension,
    );
  }
}
