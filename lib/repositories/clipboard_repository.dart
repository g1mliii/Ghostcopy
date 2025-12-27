import '../models/clipboard_item.dart';

export 'impl/clipboard_repository.dart';

/// Abstract interface for clipboard data operations
abstract class IClipboardRepository {
  /// Insert a new clipboard item and return it with generated ID
  Future<ClipboardItem> insert(ClipboardItem item);

  /// Watch clipboard history with real-time updates
  Stream<List<ClipboardItem>> watchHistory({int limit = 10});

  /// Get clipboard history (one-time fetch)
  Future<List<ClipboardItem>> getHistory({int limit = 10});

  /// Delete a clipboard item by ID
  Future<void> delete(String id);

  /// Clean up old clipboard items, keeping only the most recent [keepCount] items
  Future<void> cleanupOldItems({int keepCount = 10});

  /// Get clipboard count for the current authenticated user
  Future<int> getClipboardCountForCurrentUser();

  /// Dispose resources to prevent memory leaks
  void dispose();
}
