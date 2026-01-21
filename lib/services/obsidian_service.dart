export 'impl/obsidian_service.dart';

/// Abstract interface for Obsidian vault integration
abstract class IObsidianService {
  /// Append clipboard content to Obsidian vault file
  ///
  /// Creates file if it doesn't exist.
  /// Appends content with timestamp header.
  Future<void> appendToVault({
    required String vaultPath,
    required String fileName,
    required String content,
  });

  /// Dispose resources (no-op for this service)
  void dispose();
}
