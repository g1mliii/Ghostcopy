import 'dart:io';

import 'package:flutter/foundation.dart';

import '../obsidian_service.dart';

/// Singleton service for Obsidian vault integration
///
/// Features:
/// - Auto-append clipboard content to local Obsidian vault
/// - Creates file if doesn't exist
/// - Adds timestamp headers for each entry
/// - Local file I/O only (works on desktop and mobile)
/// - No background operations (on-demand only)
class ObsidianService implements IObsidianService {
  factory ObsidianService() => _instance;
  ObsidianService._internal();
  static final ObsidianService _instance = ObsidianService._internal();

  @override
  Future<void> appendToVault({
    required String vaultPath,
    required String fileName,
    required String content,
  }) async {
    try {
      final filePath = '$vaultPath${Platform.pathSeparator}$fileName';
      final file = File(filePath);

      debugPrint('[ObsidianService] Appending to: $filePath');

      // Create file if doesn't exist (use sync exists to avoid slow async I/O)
      if (!file.existsSync()) {
        await file.create(recursive: true);
        debugPrint('[ObsidianService] ✅ Created new file: $fileName');
      }

      // Append with timestamp
      final timestamp = DateTime.now().toString().split('.')[0]; // Remove microseconds
      final entry = '\n## $timestamp\n$content\n\n';

      await file.writeAsString(entry, mode: FileMode.append);
      debugPrint('[ObsidianService] ✅ Appended to $fileName');
    } on Exception catch (e) {
      debugPrint('[ObsidianService] ❌ Failed to append: $e');
      rethrow;
    }
  }

  @override
  void dispose() {
    // No resources to dispose (no HTTP clients, timers, or streams)
    debugPrint('[ObsidianService] ✅ Disposed');
  }
}
