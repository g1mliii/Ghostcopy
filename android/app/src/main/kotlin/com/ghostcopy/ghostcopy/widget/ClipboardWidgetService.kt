package com.ghostcopy.ghostcopy.widget

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.util.Log
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.ghostcopy.ghostcopy.R
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * RemoteViewsService for providing data to widget ListView.
 *
 * Acts as the adapter between clipboard data and the widget's ListView.
 * Data is fetched from SharedPreferences (populated by Flutter WidgetService).
 */
class ClipboardWidgetService : RemoteViewsService() {
  override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
    return ClipboardWidgetFactory(applicationContext)
  }
}

/**
 * RemoteViewsFactory implementation for clipboard items.
 *
 * Provides data to the widget's ListView, handling both text and image content.
 * Efficient memory usage - does not hold onto image data after rendering.
 *
 * Memory Management:
 * - Fetches data fresh from SharedPreferences on each access
 * - Releases bitmap immediately after RemoteViews creation
 * - Minimal in-memory state
 */
class ClipboardWidgetFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
  private var items: List<ClipboardItemData> = emptyList()
  private val dataManager = WidgetDataManager.getInstance(context)

  override fun onCreate() {
    Log.d(TAG, "ClipboardWidgetFactory created")
    onDataSetChanged()
  }

  /**
   * Called when data might have changed.
   * Re-fetches items from SharedPreferences.
   */
  override fun onDataSetChanged() {
    items = dataManager.getClipboardItems()
    Log.d(TAG, "Data refreshed: ${items.size} items")
  }

  override fun onDestroy() {
    items = emptyList()
    Log.d(TAG, "ClipboardWidgetFactory destroyed")
  }

  override fun getCount(): Int = items.size

  override fun getViewAt(position: Int): RemoteViews {
    if (position < 0 || position >= items.size) {
      return RemoteViews(context.packageName, R.layout.widget_item)
    }

    val item = items[position]
    val views = RemoteViews(context.packageName, R.layout.widget_item)

    try {
      // Set content preview text
      views.setTextViewText(R.id.content_preview, item.contentPreview)

      // Determine icon based on content type
      val iconRes = when {
        item.isImage -> R.drawable.ic_image
        item.isFile -> R.drawable.ic_file
        item.contentType == "html" -> R.drawable.ic_html_code
        item.contentType == "markdown" -> R.drawable.ic_text_snippets
        else -> R.drawable.ic_text_fields
      }
      views.setImageViewResource(R.id.content_icon, iconRes)

      // File/Image override: Show filename and size
      if (item.isFile || item.isImage) {
        val size = item.displaySize ?: ""
        val filename = item.filename ?: (if (item.isImage) "Image" else "File")
        
        views.setTextViewText(R.id.content_preview, filename)
        views.setTextViewText(R.id.timestamp, size.ifEmpty { formatTimeAgo(item.createdAt) })
      } else {
        views.setTextViewText(R.id.timestamp, formatTimeAgo(item.createdAt))
      }

      // Load and set thumbnail if available
      if (!item.thumbnailPath.isNullOrEmpty() && item.isImage) {
        try {
          val bitmap = BitmapFactory.decodeFile(item.thumbnailPath)
          if (bitmap != null) {
            views.setImageViewBitmap(R.id.thumbnail, bitmap)
            views.setViewVisibility(R.id.thumbnail, android.view.View.VISIBLE)
            views.setViewVisibility(R.id.content_icon, android.view.View.GONE)
            Log.d(TAG, "Loaded thumbnail for item ${item.id}")
          }
        } catch (e: Exception) {
          Log.e(TAG, "Failed to load thumbnail: ${e.message}")
        }
      }

      // Set fill-in intent for item click
      val fillInIntent = Intent().apply {
        putExtra(KEY_CLIPBOARD_ID, item.id)
        putExtra(KEY_CONTENT_TYPE, item.contentType)
        putExtra(KEY_CONTENT_PREVIEW, item.contentPreview)
        putExtra(KEY_THUMBNAIL_PATH, item.thumbnailPath)
        putExtra(KEY_IS_ENCRYPTED, item.isEncrypted)
        
        // Use SHARE action for files/images so they open share sheet/view immediately
        if (item.isFile || item.isImage) {
          putExtra("action", "share")
          putExtra("filename", item.filename)
        } else {
          putExtra("action", "copy")
        }
      }
      views.setOnClickFillInIntent(R.id.item_container, fillInIntent)

      return views
    } catch (e: Exception) {
      Log.e(TAG, "Error creating view at position $position: ${e.message}", e)
      return views
    }
  }

  override fun getLoadingView(): RemoteViews? = null

  override fun getViewTypeCount(): Int = 1

  override fun getItemId(position: Int): Long = position.toLong()

  override fun hasStableIds(): Boolean = true

  /**
   * Format ISO 8601 timestamp as relative time.
   */
  private fun formatTimeAgo(isoString: String): String {
    return try {
      val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
      val date = sdf.parse(isoString) ?: return "Unknown"
      val now = System.currentTimeMillis()
      val diffMs = now - date.time

      when {
        diffMs < 1000 -> "Just now"
        diffMs < 60_000 -> "${diffMs / 1000}s ago"
        diffMs < 3_600_000 -> "${diffMs / 60_000}m ago"
        diffMs < 86_400_000 -> "${diffMs / 3_600_000}h ago"
        else -> {
          val dateSdf = SimpleDateFormat("MMM d", Locale.getDefault())
          dateSdf.format(date)
        }
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to parse timestamp: ${e.message}")
      "Unknown"
    }
  }

  companion object {
    private const val TAG = "ClipboardWidgetFactory"

    // Intent extra keys for item click
    const val KEY_CLIPBOARD_ID = "clipboard_id"
    const val KEY_CONTENT_TYPE = "content_type"
    const val KEY_CONTENT_PREVIEW = "clipboard_content"
    const val KEY_THUMBNAIL_PATH = "thumbnail_path"
    const val KEY_IS_ENCRYPTED = "is_encrypted"
  }
}
