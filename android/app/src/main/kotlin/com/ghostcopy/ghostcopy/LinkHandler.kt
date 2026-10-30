package com.ghostcopy.ghostcopy

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.graphics.drawable.toBitmap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Which app opens a link, for lib/services/impl/link_handler_service.dart:
 * `{name, icon}` with the icon as PNG bytes, or null when there is no
 * default.
 *
 * Asks with the same ACTION_VIEW intent url_launcher sends, so the answer is
 * the app Open launches. When the user has not picked a default, Android
 * resolves to its chooser; then the one installed handler is the answer if
 * there is exactly one, and null - the generic glyph - if there are several,
 * since no single icon would be honest.
 *
 * Seeing other apps needs the <queries> intents in AndroidManifest.xml from
 * Android 11 on; without them every lookup comes back empty.
 */
object LinkHandler {
    private const val CHANNEL = "com.ghostcopy/link_handler"
    private const val ICON_PX = 96

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "handlerFor") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            if (url == null) {
                result.error("INVALID_ARGS", "url is required", null)
                return@setMethodCallHandler
            }
            executor.execute {
                // Throwable, so a reply always goes back: an icon is
                // decoration, never worth a Dart future that never completes.
                val handler = try {
                    lookUp(app, url)
                } catch (e: Throwable) {
                    null
                }
                main.post { result.success(handler) }
            }
        }
    }

    private fun lookUp(context: Context, url: String): Map<String, Any>? {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        val candidates = queryAll(pm, intent)
        if (candidates.isEmpty()) return null
        val resolved = resolve(pm, intent)
        val match = resolved?.let { r ->
            candidates.firstOrNull {
                it.activityInfo.packageName == r.activityInfo.packageName &&
                    it.activityInfo.name == r.activityInfo.name
            }
        } ?: candidates.singleOrNull() ?: return null

        val info = match.activityInfo
        val name = info.applicationInfo.loadLabel(pm).toString()
        val icon = try {
            png(info.loadIcon(pm))
        } catch (e: Throwable) {
            null
        }
        return buildMap<String, Any> {
            put("name", name)
            if (icon != null) put("icon", icon)
        }
    }

    private fun queryAll(pm: PackageManager, intent: Intent): List<ResolveInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }

    private fun resolve(pm: PackageManager, intent: Intent): ResolveInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.resolveActivity(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }

    /**
     * Any drawable, adaptive icons included, at [ICON_PX] square. toBitmap
     * can hand back a BitmapDrawable's own bitmap, so this one is never
     * recycled.
     */
    private fun png(drawable: android.graphics.drawable.Drawable): ByteArray {
        val out = ByteArrayOutputStream()
        drawable.toBitmap(ICON_PX, ICON_PX).compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }
}
