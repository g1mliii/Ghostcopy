package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import android.widget.Toast
import com.ghostcopy.ghostcopy.widget.ClipboardWidgetFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private companion object {
        private const val TAG = "MainActivity"
        private const val SHARE_CHANNEL = "com.ghostcopy.ghostcopy/share"
        private const val NOTIFICATION_CHANNEL = "com.ghostcopy.ghostcopy/notifications"
        private const val WIDGET_CHANNEL = "com.ghostcopy/widget"
    }

    // Method channels (stored to prevent memory leaks)
    private var shareChannel: MethodChannel? = null
    private var widgetChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Security: Prevent screenshots and recents preview
        window.setFlags(
            android.view.WindowManager.LayoutParams.FLAG_SECURE,
            android.view.WindowManager.LayoutParams.FLAG_SECURE
        )

        // Method channel for share sheet operations
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL
        )
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "shareComplete" -> {
                    // Share was processed, close the activity
                    finish()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Method channel for widget updates
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL
        )
        widgetChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    try {
                        val items = call.argument<List<Map<String, Any>>>("items")
                        val lastUpdated = call.argument<Long>("lastUpdated")

                        if (items != null && lastUpdated != null) {
                            com.ghostcopy.ghostcopy.widget.WidgetDataManager.getInstance(applicationContext)
                                .updateFromFlutter(items, lastUpdated)

                            // Notify widget to refresh
                            com.ghostcopy.ghostcopy.widget.ClipboardWidget.notifyWidgetDataChanged(applicationContext)

                            Log.d(TAG, "✅ Widget updated with ${items.size} items")
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "Missing items or lastUpdated", null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Failed to update widget: ${e.message}", e)
                        result.error("UPDATE_ERROR", e.message, null)
                    }
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
        when {
            intent.type?.startsWith("text/") == true -> {
                val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT) ?: ""
                if (sharedText.isNotEmpty()) {
                    saveSharedContentFast(sharedText)
                }
            }
            intent.type?.startsWith("image/") == true -> {
                val imageUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (imageUri != null) {
                    saveSharedImageFast(imageUri)
                }
            }
            // Handle all other file types (PDFs, DOCs, ZIPs, etc.)
            else -> {
                val fileUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (fileUri != null) {
                    saveSharedFileFast(fileUri)
                }
            }
        }
    }

    private fun saveSharedContentFast(content: String) {
        val channel = MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            SHARE_CHANNEL
        )

        // Show device selector dialog and start save in background
        channel.invokeMethod("handleShareIntent", mapOf("content" to content))
        // Save started in background, close activity immediately
        // Don't wait for save to complete
        finish()
    }

    private fun saveSharedImageFast(imageUri: Uri) {
        try {
            // Read image bytes from URI
            val inputStream = contentResolver.openInputStream(imageUri)
            val bytes = inputStream?.readBytes()
            inputStream?.close()

            if (bytes == null || bytes.isEmpty()) {
                Log.e(TAG, "❌ Failed to read image from URI: $imageUri")
                Toast.makeText(this, "Failed to read image", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // Validate size (10MB limit)
            val maxSize = 10 * 1024 * 1024 // 10MB
            if (bytes.size > maxSize) {
                Log.e(TAG, "❌ Image too large: ${bytes.size} bytes (max: $maxSize)")
                Toast.makeText(this, "Image too large (max 10MB)", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // Get MIME type
            val mimeType = contentResolver.getType(imageUri) ?: "image/*"

            val channel = MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger,
                SHARE_CHANNEL
            )

            // Pass raw bytes directly to Flutter (MethodChannel supports ByteArray → Uint8List)
            // No base64 encoding needed - saves 33% memory overhead!
            channel.invokeMethod("handleShareImage", mapOf(
                "imageBytes" to bytes,
                "mimeType" to mimeType
            ))
            // Save started in background, close activity
            finish()

            Log.d(TAG, "✅ Shared image: $mimeType, ${bytes.size / 1024}KB")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error reading shared image: ${e.message}", e)
            Toast.makeText(this, "Failed to share image", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun saveSharedFileFast(fileUri: Uri) {
        try {
            // Read file bytes from URI
            val inputStream = contentResolver.openInputStream(fileUri)
            val bytes = inputStream?.readBytes()
            inputStream?.close()

            if (bytes == null || bytes.isEmpty()) {
                Log.e(TAG, "❌ Failed to read file from URI: $fileUri")
                Toast.makeText(this, "Failed to read file", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // Validate size (10MB limit)
            val maxSize = 10 * 1024 * 1024 // 10MB
            if (bytes.size > maxSize) {
                Log.e(TAG, "❌ File too large: ${bytes.size} bytes (max: $maxSize)")
                Toast.makeText(this, "File too large (max 10MB)", Toast.LENGTH_SHORT).show()
                finish()
                return
            }

            // Get MIME type
            val mimeType = contentResolver.getType(fileUri) ?: "application/octet-stream"

            // Get original filename from URI
            val filename = contentResolver.query(fileUri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                cursor.moveToFirst()
                cursor.getString(nameIndex)
            } ?: "file"

            val channel = MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger,
                SHARE_CHANNEL
            )

            // Pass raw bytes directly to Flutter
            channel.invokeMethod("handleShareFile", mapOf(
                "fileBytes" to bytes,
                "mimeType" to mimeType,
                "filename" to filename
            ))
            // Save started in background, close activity
            finish()

            Log.d(TAG, "✅ Shared file: $filename ($mimeType), ${bytes.size / 1024}KB")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error reading shared file: ${e.message}", e)
            Toast.makeText(this, "Failed to share file", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun handleCopyAction(intent: Intent) {
        val clipboardContent = intent.getStringExtra("clipboard_content") ?: ""
        val clipboardId = intent.getStringExtra("clipboard_id") ?: ""
        val contentType = intent.getStringExtra("content_type") ?: "text"
        val richTextFormat = intent.getStringExtra("rich_text_format") ?: ""
        val deviceType = intent.getStringExtra("device_type") ?: "Another device"
        val fromNotification = intent.getBooleanExtra("from_notification", false)

        if (clipboardContent.isNotEmpty()) {
            // Direct copy from small content in FCM payload
            copyToClipboard(clipboardContent, contentType, richTextFormat, deviceType)
        } else if (clipboardId.isNotEmpty() && fromNotification) {
            // Fallback: Fetch full content from database using clipboard_id
            Log.d(TAG, "📥 Fetching clipboard item $clipboardId from database")
            fetchAndCopyClipboardItem(clipboardId, contentType, deviceType)
        }
    }

    /**
     * Copy content to system clipboard based on content type.
     * Supports: text, html, markdown, images
     */
    private fun copyToClipboard(
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
                    // Copy Markdown as plain text
                    val clip = ClipData.newPlainText("Markdown", content)
                    clipboard.setPrimaryClip(clip)
                    Log.d(TAG, "✅ Copied Markdown as plain text")
                }
                else -> {
                    // Plain text (default)
                    val clip = ClipData.newPlainText("GhostCopy", content)
                    clipboard.setPrimaryClip(clip)
                    Log.d(TAG, "✅ Copied text to clipboard")
                }
            }

            Toast.makeText(this, "Copied from $deviceType", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to copy to clipboard: ${e.message}", e)
            Toast.makeText(this, "Failed to copy", Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Fetch clipboard item from Supabase database and copy to clipboard or share.
     * Called when content is too large to fit in FCM payload.
     *
     * Uses the notifications method channel for consistency with iOS.
     */
    private fun fetchAndCopyClipboardItem(
        clipboardId: String,
        expectedContentType: String,
        deviceType: String
    ) {
        try {
            // Get Flutter engine to call Dart code for database fetch
            val channel = MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger,
                NOTIFICATION_CHANNEL
            )

            // Determine action based on content type
            // Files and images should open share sheet, text gets copied to clipboard
            val action = if (expectedContentType.startsWith("image_") || expectedContentType.startsWith("file_")) {
                "share"
            } else {
                "copy"
            }

            // Invoke Flutter method to fetch clipboard item and perform action
            // Same method call that iOS uses via AppDelegate
            channel.invokeMethod("handleNotificationAction", mapOf(
                "clipboardId" to clipboardId,
                "action" to action
            ))
            Log.d(TAG, "✅ Triggered $action action for clipboard item $clipboardId ($expectedContentType)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error fetching clipboard item: ${e.message}", e)
            Toast.makeText(this, "Failed to process item", Toast.LENGTH_SHORT).show()
        }
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
            val action = intent.getStringExtra("action") ?: "copy"

            // If action is share, delegate to Flutter to download and share
            if (action == "share" && clipboardId.isNotEmpty()) {
                Log.d(TAG, "📤 Widget share action for $clipboardId")
                fetchAndCopyClipboardItem(clipboardId, contentType, "Widget")
                return
            }

            if (contentPreview.isEmpty() && !action.equals("share")) {
                Log.w(TAG, "Empty content for clipboard item $clipboardId")
                return
            }

            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

            when {
                // Copy image from thumbnail (load actual image bytes, not text path)
                contentType.startsWith("image_") && !thumbnailPath.isNullOrEmpty() -> {
                    try {
                        val imageFile = File(thumbnailPath)
                        if (!imageFile.exists()) {
                            Log.w(TAG, "⚠️ Thumbnail file not found: $thumbnailPath")
                            showToast("Image file not found")
                            return
                        }

                        // Verify it's a valid image by attempting to decode
                        val bitmap = BitmapFactory.decodeFile(thumbnailPath)
                        if (bitmap == null) {
                            Log.w(TAG, "⚠️ Failed to decode image: $thumbnailPath")
                            showToast("Invalid image file")
                            return
                        }

                        // Recycle bitmap immediately (we only needed it for validation)
                        bitmap.recycle()

                        // Create content URI for the image file
                        val imageUri = Uri.fromFile(imageFile)

                        // Copy as image with URI (this allows paste in other apps)
                        val clip = ClipData.newUri(contentResolver, "Image", imageUri)
                        clipboard.setPrimaryClip(clip)

                        Log.d(TAG, "✅ Copied image from widget: ${imageFile.length() / 1024}KB")
                        showToast("Image copied")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Failed to copy image: ${e.message}", e)
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
            showToast("Failed to process")
        }
    }

    /**
     * Clean up method channels to prevent memory leaks.
     */
    override fun onDestroy() {
        // Remove method channel handlers
        shareChannel?.setMethodCallHandler(null)
        widgetChannel?.setMethodCallHandler(null)
        shareChannel = null
        widgetChannel = null

        super.onDestroy()
    }

    /**
     * Show a short toast message.
     */
    private fun showToast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        }
    }
}
