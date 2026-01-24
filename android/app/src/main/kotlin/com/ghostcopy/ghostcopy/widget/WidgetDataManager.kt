package com.ghostcopy.ghostcopy.widget

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken

/**
 * Manages widget data persistence using SharedPreferences.
 *
 * Stores the 5 most recent clipboard items for display in home screen widget.
 * Data is synchronized from the Flutter app via method channel.
 *
 * Memory Management:
 * - Singleton pattern ensures only one SharedPreferences instance
 * - No long-lived references to clipboard data
 * - Efficient JSON serialization/deserialization
 */
class WidgetDataManager(private val context: Context) {
  private val prefs: SharedPreferences = context.getSharedPreferences(
    PREFS_NAME,
    Context.MODE_PRIVATE
  )
  private val gson = Gson()

  /**
   * Save clipboard items to shared preferences.
   * Stores the items as a JSON array and updates the last updated timestamp.
   */
  fun saveClipboardItems(items: List<ClipboardItemData>) {
    try {
      val json = gson.toJson(items)
      prefs.edit().apply {
        putString(KEY_CLIPBOARD_ITEMS, json)
        putLong(KEY_LAST_UPDATED, System.currentTimeMillis())
        apply()
      }
      Log.d(TAG, "✅ Saved ${items.size} items to widget preferences")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to save clipboard items: ${e.message}", e)
    }
  }

  /**
   * Get all saved clipboard items from shared preferences.
   */
  fun getClipboardItems(): List<ClipboardItemData> {
    return try {
      val json = prefs.getString(KEY_CLIPBOARD_ITEMS, null) ?: return emptyList()
      val type = object : TypeToken<List<ClipboardItemData>>() {}.type
      gson.fromJson(json, type)
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to load clipboard items: ${e.message}", e)
      emptyList()
    }
  }

  /**
   * Get the timestamp of the last widget update.
   */
  fun getLastUpdated(): Long {
    return prefs.getLong(KEY_LAST_UPDATED, 0)
  }

  /**
   * Add a new clipboard item to the widget (from FCM notification).
   * Inserts at position 0 and keeps max 5 items.
   */
  fun addNewClip(item: ClipboardItemData) {
    try {
      val currentItems = getClipboardItems().toMutableList()
      // Insert at beginning
      currentItems.add(0, item)
      // Keep max 5 items
      val trimmed = if (currentItems.size > 5) {
        currentItems.take(5)
      } else {
        currentItems
      }
      saveClipboardItems(trimmed)
      Log.d(TAG, "✅ Added new clip (${trimmed.size} total)")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to add new clip: ${e.message}", e)
    }
  }

  /**
   * Clear all widget data.
   */
  fun clearAll() {
    try {
      prefs.edit().apply {
        remove(KEY_CLIPBOARD_ITEMS)
        remove(KEY_LAST_UPDATED)
        apply()
      }
      Log.d(TAG, "✅ Cleared all widget data")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to clear widget data: ${e.message}", e)
    }
  }

  /**
   * Update widget data from Flutter method channel.
   * Converts Map format from Flutter to ClipboardItemData.
   */
  fun updateFromFlutter(items: List<Map<String, Any>>, lastUpdated: Long) {
    try {
      val clipboardItems = items.mapNotNull { item ->
        try {
          ClipboardItemData(
            id = item["id"] as? String ?: return@mapNotNull null,
            contentType = item["contentType"] as? String ?: "text",
            contentPreview = item["contentPreview"] as? String ?: "",
            thumbnailPath = item["thumbnailPath"] as? String,
            deviceType = item["deviceType"] as? String ?: "unknown",
            createdAt = item["createdAt"] as? String ?: "",
            isEncrypted = item["isEncrypted"] as? Boolean ?: false
          )
        } catch (e: Exception) {
          Log.e(TAG, "❌ Failed to parse item: ${e.message}")
          null
        }
      }

      saveClipboardItems(clipboardItems)
      prefs.edit().putLong(KEY_LAST_UPDATED, lastUpdated).apply()

      Log.d(TAG, "✅ Updated from Flutter: ${clipboardItems.size} items")
    } catch (e: Exception) {
      Log.e(TAG, "❌ Failed to update from Flutter: ${e.message}", e)
    }
  }

  companion object {
    private const val TAG = "WidgetDataManager"
    private const val PREFS_NAME = "ghostcopy_widget_prefs"
    private const val KEY_CLIPBOARD_ITEMS = "widget_clipboard_items"
    private const val KEY_LAST_UPDATED = "widget_last_updated"

    @Volatile
    private var instance: WidgetDataManager? = null

    fun getInstance(context: Context): WidgetDataManager =
        instance ?: synchronized(this) {
          instance ?: WidgetDataManager(context.applicationContext).also { instance = it }
        }
  }
}

/**
 * Data class for clipboard items stored in widget.
 *
 * Lightweight representation optimized for widget display and JSON serialization.
 */
data class ClipboardItemData(
  val id: String,
  val contentType: String,
  val contentPreview: String,
  val thumbnailPath: String?,
  val deviceType: String,
  val createdAt: String,
  val isEncrypted: Boolean,
)
