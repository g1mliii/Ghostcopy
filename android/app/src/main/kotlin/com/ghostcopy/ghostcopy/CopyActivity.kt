package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.io.File

/**
 * Transparent activity that copies a clip and closes immediately.
 *
 * Reached by tapping a push notification: the backend sets click_action to
 * COPY_ACTION, and the FCM SDK builds that PendingIntent inside this app's own
 * process, so it can start this activity despite exported="false".
 *
 * Why an Activity at all, rather than a receiver or the background isolate?
 * Android 10+ gates clipboard access on being the focused window, so a
 * background write is refused. A translucent, no-history activity holds focus
 * for the few frames it needs and never appears to the user.
 *
 * Content never travels through push. The FCM background isolate fetches and
 * decrypts the clip when the notification arrives and stages it in filesDir;
 * this activity is a local read plus a clipboard write, typically ~100ms.
 *
 * Handles text, HTML and markdown. Images and files are not staged - they need
 * a download and a share sheet - so those fall through to MainActivity.
 */
class CopyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Note: `clipboard_content` is deliberately NOT read from the intent any
        // more. The backend never sends a clipboard value through push, so that
        // extra was always empty in practice, and honouring it would mean writing
        // intent-supplied text straight to the clipboard. Content comes from the
        // staged file below, which only this app can write.
        val clipboardId = intent.getStringExtra("clipboard_id") ?: ""
        val contentType = intent.getStringExtra("content_type") ?: "text"
        val richTextFormat = intent.getStringExtra("rich_text_format") ?: ""
        val deviceType = intent.getStringExtra("device_type") ?: "Another device"

        val staged = readStagedClip(clipboardId)

        Log.d(TAG, "📋 CopyActivity: id=$clipboardId, type=$contentType, staged=${staged != null}")

        if (staged != null) {
            // Fast path: the background isolate already fetched and decrypted this
            // clip when the push arrived, so this is a local read and a clipboard
            // write - no network, no Flutter engine, nothing visible on screen.
            copyContentToClipboard(
                staged.optString("content"),
                staged.optString("contentType", contentType),
                staged.optString("richTextFormat", richTextFormat),
                deviceType,
            )
            clearStagedClip()
            finish()
        } else if (clipboardId.isNotEmpty()) {
            // Slow path: nothing staged (prefetch failed, an image or file, or the
            // user tapped before it finished). Hand off to the app, which can fetch
            // and share properly.
            Log.d(TAG, "📥 Nothing staged for $clipboardId - handing off to MainActivity")

            val intent = Intent(this, MainActivity::class.java).apply {
                action = "com.ghostcopy.ghostcopy.COPY_ACTION"
                putExtra("clipboard_id", clipboardId)
                putExtra("content_type", contentType)
                putExtra("rich_text_format", richTextFormat)
                putExtra("device_type", deviceType)
                putExtra("from_notification", true)
            }
            startActivity(intent)
            finish()
        } else {
            Log.w(TAG, "⚠️ CopyActivity: No clipboard_id provided")
            finish()
        }
    }

    /**
     * Read the clip staged by the FCM background isolate, if it is the one this
     * notification refers to.
     *
     * Returns null whenever the staged clip is missing, unreadable, or for a
     * different id - every one of which means "fall back to opening the app".
     */
    private fun readStagedClip(clipboardId: String): JSONObject? {
        if (clipboardId.isEmpty()) return null

        return try {
            val file = File(filesDir, PENDING_COPY_FILE)
            if (!file.exists()) return null

            val staged = JSONObject(file.readText())
            // A stale file from an earlier clip must never be copied for this one.
            if (staged.optString("id") != clipboardId) {
                Log.d(TAG, "Staged clip is for a different id - ignoring")
                return null
            }
            if (staged.optString("content").isEmpty()) null else staged
        } catch (e: Exception) {
            Log.w(TAG, "Could not read staged clip: ${e.message}")
            null
        }
    }

    /** Plaintext is kept only until it is used - delete as soon as it is read. */
    private fun clearStagedClip() {
        try {
            File(filesDir, PENDING_COPY_FILE).delete()
        } catch (e: Exception) {
            Log.w(TAG, "Could not clear staged clip: ${e.message}")
        }
    }

    /**
     * Copy content to system clipboard based on content type
     * Supports: text, html, markdown
     * Images require fallback fetch from database
     */
    private fun copyContentToClipboard(
        content: String,
        contentType: String,
        richTextFormat: String,
        deviceType: String
    ) {
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

            when {
                contentType == "html" -> {
                    // Copy HTML with plain text fallback
                    val plainText = content.replace(Regex("<[^>]*>"), "")
                    val clip = ClipData.newHtmlText("HTML", plainText, content)
                    clipboard.setPrimaryClip(clip)
                    Log.d(TAG, "✅ Copied HTML to clipboard")
                }
                contentType == "markdown" -> {
                    // Copy Markdown as plain text (no standard clipboard format for markdown)
                    val clip = ClipData.newPlainText("Markdown", content)
                    clipboard.setPrimaryClip(clip)
                    Log.d(TAG, "✅ Copied Markdown as plain text")
                }
                contentType.startsWith("image_") -> {
                    // Images should use fallback mechanism, not this path
                    Log.w(TAG, "⚠️ Image should use fallback mechanism")
                }
                else -> {
                    // Plain text (default)
                    val clip = ClipData.newPlainText("GhostCopy", content)
                    clipboard.setPrimaryClip(clip)
                    Log.d(TAG, "✅ Copied text to clipboard")
                }
            }

            // Always confirm, on every API level. Android 13+ does have its own
            // clipboard confirmation, but it does not fire for this flow - the
            // translucent activity writes the clip and finishes before the system
            // UI ever latches on, so suppressing ours left the tap with no visible
            // feedback at all. A silent copy is indistinguishable from a broken one.
            Toast.makeText(
                this,
                "Copied to clipboard",
                Toast.LENGTH_SHORT
            ).show()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to copy to clipboard: ${e.message}", e)
            Toast.makeText(this, "Failed to copy", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        private const val TAG = "CopyActivity"

        // Written by _writePendingCopy() in main.dart, into the same directory
        // path_provider's getApplicationSupportDirectory() maps to on Android.
        private const val PENDING_COPY_FILE = "pending_copy.json"
    }
}
