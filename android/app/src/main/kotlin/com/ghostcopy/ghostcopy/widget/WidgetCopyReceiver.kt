package com.ghostcopy.ghostcopy.widget

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import com.ghostcopy.ghostcopy.IntentAuth
import com.ghostcopy.ghostcopy.MainActivity
import java.io.File

/**
 * Handles taps on a widget row.
 *
 * A BroadcastReceiver rather than MainActivity, so copying does not drag the
 * app to the foreground. Every widget tap used to launch MainActivity - even a
 * short text clip that needs nothing but a clipboard write - which made the
 * Android widget markedly worse to use than the iOS one, where the copy intent
 * runs inside the widget process and nothing appears on screen.
 *
 * Not exported: a PendingIntent is sent with this app's identity, so the
 * launcher holding the template can fire it without the receiver being
 * reachable by anyone else. The IntentAuth token is still checked, because the
 * share branch below hands off to MainActivity, which *is* exported.
 */
class WidgetCopyReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (!IntentAuth.isTrusted(context, intent.getStringExtra(IntentAuth.EXTRA_TOKEN))) {
            Log.w(TAG, "⚠️ Rejected widget tap from an untrusted caller")
            return
        }

        val clipboardId = intent.getStringExtra(ClipboardWidgetFactory.KEY_CLIPBOARD_ID) ?: ""
        val contentType = intent.getStringExtra(ClipboardWidgetFactory.KEY_CONTENT_TYPE) ?: "text"
        val copyPath = intent.getStringExtra(ClipboardWidgetFactory.KEY_COPY_PATH) ?: ""
        val copyKind = intent.getStringExtra(ClipboardWidgetFactory.KEY_COPY_KIND) ?: "text"
        val action = intent.getStringExtra("action") ?: "copy"

        // Clips with no staged payload - a zip, an mp4 - have nothing worth
        // putting on a clipboard and need the app's share sheet.
        if (action == "share" || copyPath.isEmpty()) {
            handOffToApp(context, intent, clipboardId, contentType)
            return
        }

        try {
            val payload = File(copyPath)
            if (!payload.exists()) {
                Log.w(TAG, "⚠️ Staged payload missing: $copyPath")
                toast(context, "Open GhostCopy to sync this clip")
                return
            }

            val clipboard =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

            if (copyKind == "image") {
                // A content:// URI through the FileProvider, not Uri.fromFile:
                // a file:// URI handed to another app trips
                // FileUriExposedException on Android 7+.
                val uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    payload,
                )
                clipboard.setPrimaryClip(
                    ClipData.newUri(context.contentResolver, "Image", uri),
                )
                toast(context, "Image copied")
            } else {
                // The full clip, read from the staged file. This used to be the
                // row's preview text, which is truncated for display - so any
                // longer clip put a mangled string on the clipboard and looked
                // like it had worked.
                val text = payload.readText()
                val clip = when (contentType) {
                    "html" -> ClipData.newHtmlText("HTML", text, text)
                    "markdown" -> ClipData.newPlainText("Markdown", text)
                    else -> ClipData.newPlainText("GhostCopy", text)
                }
                clipboard.setPrimaryClip(clip)
                toast(context, "Copied")
            }

            Log.d(TAG, "✅ Copied widget item $clipboardId ($copyKind)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to copy widget item: ${e.message}", e)
            toast(context, "Failed to copy")
        }
    }

    /** Files with no useful paste target go to the app, which can share them. */
    private fun handOffToApp(
        context: Context,
        source: Intent,
        clipboardId: String,
        contentType: String,
    ) {
        if (clipboardId.isEmpty()) {
            Log.w(TAG, "⚠️ Widget tap with no clipboard id")
            return
        }

        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_WIDGET_ITEM_CLICK
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            putExtra(ClipboardWidgetFactory.KEY_CLIPBOARD_ID, clipboardId)
            putExtra(ClipboardWidgetFactory.KEY_CONTENT_TYPE, contentType)
            putExtra("action", "share")
            putExtra("filename", source.getStringExtra("filename"))
            putExtra(IntentAuth.EXTRA_TOKEN, IntentAuth.token(context))
        }
        context.startActivity(intent)
    }

    /** Toasts must be posted to the main looper; a receiver runs off it. */
    private fun toast(context: Context, message: String) {
        Handler(Looper.getMainLooper()).post {
            Toast.makeText(context.applicationContext, message, Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        private const val TAG = "WidgetCopyReceiver"
        const val ACTION_WIDGET_ITEM_CLICK = "com.ghostcopy.ghostcopy.WIDGET_ITEM_CLICK"
    }
}
