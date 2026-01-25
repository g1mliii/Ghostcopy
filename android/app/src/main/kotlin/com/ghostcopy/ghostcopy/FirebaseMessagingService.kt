package com.ghostcopy.ghostcopy

import android.appwidget.AppWidgetManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import com.ghostcopy.ghostcopy.R
import com.ghostcopy.ghostcopy.widget.ClipboardWidget
import com.ghostcopy.ghostcopy.widget.ClipboardItemData
import com.ghostcopy.ghostcopy.widget.WidgetDataManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.time.Instant

/**
 * Background service that handles FCM messages when app is not running.
 *
 * Responsibilities:
 * 1. Copy clipboard content to device clipboard (auto-copy feature)
 * 2. Update widget with new clipboard item
 * 3. Handle different content types
 *
 * Memory Management:
 * - Does not hold onto large image data
 * - Releases clipboard data after copying
 * - SharedPreferences used for persistence, not in-memory storage
 */
class FirebaseMessagingService : FirebaseMessagingService() {
  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    try {
      // Extract FCM data
      val data = remoteMessage.data
      val clipboardId = data["clipboard_id"] ?: ""
      val clipboardContent = data["clipboard_content"] ?: ""
      val deviceType = data["device_type"] ?: "Another device"
      val contentType = data["content_type"] ?: "text"
      val fileSize = data["file_size"]
      val filename = data["filename"]
      val mimeType = data["mime_type"]

      Log.d(TAG, "📬 FCM received: id=$clipboardId, type=$contentType, size=${clipboardContent.length}")

      // Determine if this is a file/image
      val isFile = contentType.startsWith("file_")
      val isImage = contentType.startsWith("image_")

      // 1. Auto-copy to clipboard OR notify for files
      if (isFile || isImage) {
        // Files/images cannot be auto-copied to clipboard on Android
        // User must tap notification to download and share
        Log.d(TAG, "📎 File/image notification - user must tap to download")
      } else if (clipboardContent.isNotEmpty()) {
        // Text content - auto-copy to clipboard
        autoCopyToClipboard(clipboardContent)
        Log.d(TAG, "✅ Auto-copied content from $deviceType")
      }

      // 2. Update widget with new item (including file metadata)
      if (clipboardId.isNotEmpty()) {
        updateWidgetWithNewClip(
          clipboardId = clipboardId,
          contentType = contentType,
          contentPreview = clipboardContent,
          isFile = isFile,
          isImage = isImage,
          displaySize = fileSize,
          filename = filename
        )
      }
    } catch (e: Exception) {
      Log.e(TAG, "❌ Error processing FCM message: ${e.message}", e)
    }
  }

  /**
   * Copy content to device clipboard (auto-copy feature).
   */
  private fun autoCopyToClipboard(content: String) {
    try {
      val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      val clip = ClipData.newPlainText("GhostCopy", content)
      clipboard.setPrimaryClip(clip)
      Log.d(TAG, "✅ Clipboard updated: ${content.length} characters")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to copy to clipboard: ${e.message}")
    }
  }

  /**
   * Update widget with new clipboard item from FCM notification.
   *
   * Creates a ClipboardItemData from FCM payload and inserts at the beginning.
   * Keeps max 5 items.
   */
  private fun updateWidgetWithNewClip(
    clipboardId: String,
    contentType: String,
    contentPreview: String,
    isFile: Boolean = false,
    isImage: Boolean = false,
    displaySize: String? = null,
    filename: String? = null,
  ) {
    try {
      val dataManager = WidgetDataManager.getInstance(this)

      // Generate appropriate preview text
      val preview = when {
        isFile && filename != null -> filename
        isImage && displaySize != null -> "Image ($displaySize)"
        else -> contentPreview.take(100)
      }

      // Create widget item data from FCM payload
      val newItem = ClipboardItemData(
        id = clipboardId,
        contentType = contentType,
        contentPreview = preview,
        thumbnailPath = null, // Images downloaded separately
        deviceType = "mobile",
        createdAt = Instant.now().toString(),
        isEncrypted = false, // FCM data is unencrypted
        isFile = isFile,
        isImage = isImage,
        displaySize = displaySize,
        filename = filename
      )

      // Add to widget data (will be inserted at position 0, max 5 items)
      dataManager.addNewClip(newItem)

      // Notify widget to update
      notifyWidgetUpdate()

      Log.d(TAG, "✅ Updated widget with new clip: $clipboardId (isFile=$isFile, isImage=$isImage)")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to update widget: ${e.message}", e)
    }
  }

  /**
   * Notify widget that data has changed.
   *
   * Triggers ListView to reload from RemoteViewsFactory.
   */
  private fun notifyWidgetUpdate() {
    try {
      val appWidgetManager = AppWidgetManager.getInstance(this)
      val componentName = ComponentName(this, ClipboardWidget::class.java)
      val widgetIds = appWidgetManager.getAppWidgetIds(componentName)

      if (widgetIds.isNotEmpty()) {
        appWidgetManager.notifyAppWidgetViewDataChanged(widgetIds, R.id.widget_list)
        Log.d(TAG, "✅ Notified widget to update (${widgetIds.size} widgets)")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to notify widget: ${e.message}")
    }
  }

  override fun onNewToken(token: String) {
    // Token refresh handled by Flutter FCM service
    Log.d(TAG, "🔄 FCM token refreshed")
    super.onNewToken(token)
  }

  companion object {
    private const val TAG = "FirebaseMessagingService"
  }
}
