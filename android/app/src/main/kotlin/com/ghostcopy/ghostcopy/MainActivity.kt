package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast
import com.ghostcopy.ghostcopy.widget.ClipboardWidgetFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private companion object {
        private const val CHANNEL = "com.ghostcopy.ghostcopy/share"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Method channel for share sheet operations
        io.flutter.embedding.engine.systemchannels.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareComplete" -> {
                    // Share was processed, close the activity
                    finish()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent) // Update the intent so Flutter can access it

        // Handle share intent from another app
        if (intent.action == Intent.ACTION_SEND) {
            handleShareIntent(intent)
        } else if (intent.action == "com.ghostcopy.ghostcopy.COPY_ACTION") {
            // Handle notification tap while app is running
            handleCopyAction(intent)
        } else if (intent.action == "com.ghostcopy.ghostcopy.WIDGET_ITEM_CLICK") {
            // Handle widget item tap (copy to clipboard)
            handleWidgetItemClick(intent)
        }
    }

    private fun handleShareIntent(intent: Intent) {
        val sharedText = when {
            intent.type?.startsWith("text/") == true -> {
                intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
            }
            else -> ""
        }

        if (sharedText.isNotEmpty()) {
            // Call Flutter method to save content
            saveSharedContentFast(sharedText)
        }
    }

    private fun saveSharedContentFast(content: String) {
        val channel = io.flutter.embedding.engine.systemchannels.MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            CHANNEL
        )

        // Show device selector dialog and start save in background
        channel.invokeMethod("handleShareIntent", mapOf("content" to content)) { result ->
            // Save started in background, close activity immediately
            // Don't wait for save to complete
            finish()
        }
    }

    private fun handleCopyAction(intent: Intent) {
        val clipboardContent = intent.getStringExtra("clipboard_content") ?: return
        if (clipboardContent.isEmpty()) return

        // Copy to clipboard
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("GhostCopy", clipboardContent)
        clipboard.setPrimaryClip(clip)
    }

    /**
     * Handle widget item click - copy content to device clipboard.
     *
     * Supports different content types:
     * - Text, HTML, Markdown: Copy as plain or rich text
     * - Images: Copy from cached thumbnail
     * - Encrypted: Copy encrypted text (user decrypts in app)
     */
    private fun handleWidgetItemClick(intent: Intent) {
        try {
            val clipboardId = intent.getStringExtra(ClipboardWidgetFactory.KEY_CLIPBOARD_ID) ?: ""
            val contentType = intent.getStringExtra(ClipboardWidgetFactory.KEY_CONTENT_TYPE) ?: "text"
            val contentPreview = intent.getStringExtra(ClipboardWidgetFactory.KEY_CONTENT_PREVIEW) ?: ""
            val thumbnailPath = intent.getStringExtra(ClipboardWidgetFactory.KEY_THUMBNAIL_PATH)
            val isEncrypted = intent.getBooleanExtra(ClipboardWidgetFactory.KEY_IS_ENCRYPTED, false)

            if (contentPreview.isEmpty()) {
                Log.w(TAG, "Empty content for clipboard item $clipboardId")
                return
            }

            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

            when {
                // Copy image from thumbnail
                contentType.startsWith("image_") && !thumbnailPath.isNullOrEmpty() -> {
                    try {
                        // For images, we copy the thumbnail path as a URI
                        // The actual image is cached on device
                        val clip = ClipData.newPlainText("Image path", thumbnailPath)
                        clipboard.setPrimaryClip(clip)
                        showToast("Image copied")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to copy image: ${e.message}")
                        showToast("Failed to copy image")
                    }
                }
                // Copy HTML content
                contentType == "html" -> {
                    val clip = ClipData.newHtmlText("HTML", contentPreview, contentPreview)
                    clipboard.setPrimaryClip(clip)
                    showToast("HTML copied")
                }
                // Copy markdown as plain text (iOS limitation - no markdown mime type)
                contentType == "markdown" -> {
                    val clip = ClipData.newPlainText("Markdown", contentPreview)
                    clipboard.setPrimaryClip(clip)
                    showToast("Markdown copied")
                }
                // Copy encrypted content (will show lock icon in app)
                isEncrypted -> {
                    val clip = ClipData.newPlainText("Encrypted", contentPreview)
                    clipboard.setPrimaryClip(clip)
                    showToast("Encrypted content copied")
                }
                // Copy plain text (default)
                else -> {
                    val clip = ClipData.newPlainText("Text", contentPreview)
                    clipboard.setPrimaryClip(clip)
                    showToast("Copied")
                }
            }

            Log.d(TAG, "✅ Widget item copied: $contentType")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to handle widget item click: ${e.message}", e)
            showToast("Failed to copy")
        }
    }

    /**
     * Show a short toast message.
     */
    private fun showToast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        }
    }

    private companion object {
        private const val TAG = "MainActivity"
    }
}
