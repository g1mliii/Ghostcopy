package com.ghostcopy.ghostcopy

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * HEIC/HEIF to JPEG through the platform decoder, for
 * lib/services/image_transcoder.dart. Mirrors ImageTranscoder in
 * ios/Runner/FlutterChannelHub.swift.
 *
 * ImageDecoder reads HEIF from API 28. Below that this answers null and the
 * photo goes as the original file, as it always did.
 */
object ImageTranscoder {
    private const val CHANNEL = "com.ghostcopy/image_transcoder"

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "toJpeg") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val maxBytes = call.argument<Int>("maxBytes")
            // Sizing comes from lib/utils/image_shrink.dart, so the two agree.
            val maxSide = call.argument<Int>("maxSide")
            val minSide = call.argument<Int>("minSide")
            val quality = call.argument<Int>("quality")
            if (path == null || maxBytes == null || maxSide == null ||
                minSide == null || quality == null) {
                result.error("INVALID_ARGS", "path, maxBytes and sizing are required", null)
                return@setMethodCallHandler
            }
            executor.execute {
                // Throwable, not Exception: a large HEIC decoded on a phone
                // short of memory throws OutOfMemoryError, and an escaped
                // throw never replies - the Dart side then waits forever with
                // its upload spinner on.
                val jpeg = try {
                    toJpeg(path, maxBytes, maxSide, minSide, quality)
                } catch (e: Throwable) {
                    null
                }
                main.post { result.success(jpeg) }
            }
        }
    }

    /** Halves the longest side from [maxSide] until the JPEG fits. */
    private fun toJpeg(
        path: String,
        maxBytes: Int,
        maxSide: Int,
        minSide: Int,
        quality: Int,
    ): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val source = ImageDecoder.createSource(File(path))
        var longest = 0
        var side = maxSide
        while (true) {
            // Decoded straight to the target size, so the full-resolution
            // image is never held. ImageDecoder applies EXIF orientation.
            val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val w = info.size.width
                val h = info.size.height
                longest = maxOf(w, h)
                val target = minOf(side, longest)
                val scale = target.toDouble() / longest
                decoder.setTargetSize(
                    maxOf(1, (w * scale).toInt()),
                    maxOf(1, (h * scale).toInt()),
                )
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            bitmap.recycle()
            if (out.size() <= maxBytes) return out.toByteArray()
            side = minOf(side, longest) / 2
            if (side < minOf(minSide, longest)) return null
        }
    }
}
