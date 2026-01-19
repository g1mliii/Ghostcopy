package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * Transparent activity that copies clipboard content and closes immediately.
 * Triggered when user taps push notification.
 *
 * Supports multiple content types with fallback:
 * - Small content (<4KB): Copies directly from FCM data payload
 * - Large content/images: Sends clipboard_id to MainActivity for database fetch
 *
 * Content Types Supported:
 * - text: Plain text
 * - html: HTML with plain text fallback
 * - markdown: Markdown as plain text
 * - image_*: Image (requires fallback fetch from DB)
 */
class CopyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Extract data from notification intent
        val clipboardContent = intent.getStringExtra("clipboard_content") ?: ""
        val clipboardId = intent.getStringExtra("clipboard_id") ?: ""
        val contentType = intent.getStringExtra("content_type") ?: "text"
        val richTextFormat = intent.getStringExtra("rich_text_format") ?: ""
        val deviceType = intent.getStringExtra("device_type") ?: "Another device"
        val isImage = intent.getStringExtra("is_image") == "true"

        Log.d(TAG, "📋 CopyActivity: id=$clipboardId, type=$contentType, hasContent=${clipboardContent.isNotEmpty()}")

        if (clipboardContent.isNotEmpty()) {
            // Case 1: Small content available in FCM payload
            copyContentToClipboard(clipboardContent, contentType, richTextFormat, deviceType)
            finish()
        } else if (clipboardId.isNotEmpty()) {
            // Case 2: Fallback - large content or image, need to fetch from database
            Log.d(TAG, "📥 Fallback: Fetching clipboard item $clipboardId from database via MainActivity")

            // Forward to MainActivity with clipboard_id to fetch and copy via method channel
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
            // No content and no ID - nothing to copy
            Log.w(TAG, "⚠️ CopyActivity: No content or clipboard_id provided")
            finish()
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

            // Show toast confirmation (invisible sync - can be removed if desired)
            Toast.makeText(
                this,
                "Copied from $deviceType",
                Toast.LENGTH_SHORT
            ).show()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to copy to clipboard: ${e.message}", e)
            Toast.makeText(this, "Failed to copy", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        private const val TAG = "CopyActivity"
    }
}
