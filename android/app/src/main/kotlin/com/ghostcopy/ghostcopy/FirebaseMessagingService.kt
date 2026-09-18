package com.ghostcopy.ghostcopy

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Background service that handles FCM messages when app is not running.
 *
 * The push payload carries NO clipboard content by design - only
 * clipboard_id, device_type and content_type. This service therefore does not
 * copy anything from the message; it only records that a push named this clip,
 * so a later notification tap can be trusted.
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
      // and is_encrypted, none of which are sent any more; clipboard_content
      // was always "", so nothing built from it could be anything but empty.
      // So: do not copy and do not fabricate anything from the push. The clip
      // is fetched from the database, where it actually is, when the user
      // taps.
      val data = remoteMessage.data
      val clipboardId = data["clipboard_id"] ?: ""
      val deviceType = data["device_type"] ?: "Another device"
      val contentType = data["content_type"] ?: "text"

      Log.d(TAG, "📬 FCM signal: id=$clipboardId, type=$contentType, from=$deviceType")

      if (clipboardId.isNotEmpty()) {
        // Note that a push really did name this clip, so that a notification
        // tap can later be told apart from a third-party app inventing an id
        // and sending it to the exported launcher. See PushRegistry.
        PushRegistry.record(applicationContext, clipboardId)
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
