package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * Transparent activity that copies clipboard content and closes immediately.
 * Triggered when user taps push notification.
 */
class CopyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Extract clipboard content from notification intent
        val clipboardContent = intent.getStringExtra("clipboard_content") ?: ""
        val deviceType = intent.getStringExtra("device_type") ?: "Another device"

        if (clipboardContent.isNotEmpty()) {
            // Copy to system clipboard
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("GhostCopy", clipboardContent)
            clipboard.setPrimaryClip(clip)

            // Optional: Brief toast confirmation (can remove for truly invisible sync)
            Toast.makeText(
                this,
                "Copied from $deviceType",
                Toast.LENGTH_SHORT
            ).show()
        }

        // Close activity immediately
        finish()
    }
}
