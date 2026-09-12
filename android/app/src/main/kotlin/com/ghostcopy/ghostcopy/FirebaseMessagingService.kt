package com.ghostcopy.ghostcopy

import android.util.Log
import com.ghostcopy.ghostcopy.widget.WidgetRefreshWorker
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Background service that handles FCM messages when app is not running.
 *
 * The push payload carries NO clipboard content by design - only
 * clipboard_id, device_type and content_type. This service therefore does not
 * copy anything or build widget rows from the message; it schedules a widget
 * refresh that re-reads the row from the database as the authenticated user.
 */
class FirebaseMessagingService : FirebaseMessagingService() {
  override fun onMessageReceived(remoteMessage: RemoteMessage) {
    try {
      // The push is a SIGNAL, not a payload.
      //
      // The backend deliberately sends only clipboard_id, device_type and
      // content_type - "Push infrastructure and OS notification history must
      // never receive a clipboard value, preview, filename, or size". This
      // handler used to read clipboard_content, file_size, filename, mime_type
      // and is_encrypted, none of which are sent any more:
      //   * clipboard_content was always "", so auto-copy never ran, and
      //   * updateWidgetWithNewClip was still called with that empty string,
      //     inserting a BLANK row into the home-screen widget on every push and
      //     pushing real entries out of the 5-item list.
      // So: do not copy, do not fabricate a widget row. Ask the widget to
      // re-read from the database, where the row actually is.
      val data = remoteMessage.data
      val clipboardId = data["clipboard_id"] ?: ""
      val deviceType = data["device_type"] ?: "Another device"
      val contentType = data["content_type"] ?: "text"

      Log.d(TAG, "📬 FCM signal: id=$clipboardId, type=$contentType, from=$deviceType")

      if (clipboardId.isNotEmpty()) {
        // Re-reads the authenticated user's clips from the DB and refreshes the
        // widget, so the content never travels through push infrastructure.
        WidgetRefreshWorker.scheduleRefresh(applicationContext)
        Log.d(TAG, "🔄 Scheduled widget refresh from database")
      }
    } catch (e: Exception) {
      Log.e(TAG, "❌ Error processing FCM message: ${e.message}", e)
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
