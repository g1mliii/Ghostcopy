import '../models/clipboard_item.dart';

/// Abstract interface for clipboard data operations
abstract class IClipboardRepository {
  /// Insert a new clipboard item
  Future<void> insert(ClipboardItem item);
  
  /// Watch clipboard history with real-time updates
  Stream<List<ClipboardItem>> watchHistory({int limit = 50});
  
  /// Get clipboard history (one-time fetch)
  Future<List<ClipboardItem>> getHistory({int limit = 50});
  
  /// Delete a clipboard item by ID
  Future<void> delete(String id);
}
