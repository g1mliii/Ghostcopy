package com.ghostcopy.ghostcopy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        private const val TAG = "MainActivity"

        // Mirrors _notificationChannel in mobile_main_screen.dart and
        // FlutterChannelHub.notificationChannelName on iOS.
        private const val NOTIFICATION_CHANNEL = "com.ghostcopy.ghostcopy/notifications"

        // Must match the manifest's default_notification_channel_id, the
        // channelId the edge function sets on the push, and the channel
        // flutter_local_notifications uses for in-app notifications.
        private const val NOTIFICATION_CHANNEL_ID = "ghostcopy_notifications"

        // Mirrors _keyScreenshotProtection in settings_service.dart.
        private const val PREF_SCREENSHOT_PROTECTION = "screenshot_protection"
    }

    // Guards against re-copying the same clip every time the activity resumes
    // while a notification-launched intent is still attached.
    private var lastHandledFcmClipboardId: String? = null

    // A notification action that Dart has not collected yet. Written whenever a
    // tap is handled, cleared when Dart drains it through
    // "takePendingNotificationAction". This is what makes a cold-start tap work:
    // the action waits here instead of being fired at a Dart handler that does
    // not exist yet.
    private var pendingNotificationAction: Map<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        ensureNotificationChannel()

        applyScreenshotProtection()

        // Native toast channel. Flutter's in-app toast is a custom overlay that
        // does not look like the platform, so short confirmations ("Copied to
        // clipboard") go through android.widget.Toast instead.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIFICATION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showNativeToast" -> {
                    val message = call.argument<String>("message")
                    if (message.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "message is required", null)
                    } else {
                        val long = call.argument<Boolean>("long") ?: false
                        Toast.makeText(
                            this,
                            message,
                            if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT,
                        ).show()
                        result.success(true)
                    }
                }
                "setScreenshotProtection" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled == null) {
                        result.error("INVALID_ARGS", "enabled is required", null)
                    } else {
                        setSecureFlag(enabled)
                        result.success(true)
                    }
                }
                // Drain a notification tap that arrived before Dart was ready.
                //
                // onResume() fires while the Dart entrypoint is still booting on
                // a cold start, so pushing the action at Dart (invokeMethod) is
                // a race the push loses: MobileMainScreen.initState() registers
                // the receiving handler over a second later, and a platform ->
                // Dart message with no handler is discarded silently. This
                // handler is registered in configureFlutterEngine, i.e. before
                // the entrypoint runs, so it is always ready to be asked.
                // Same verb as FlutterChannelHub on iOS. Dart drains through one
                // non-platform-branched code path, so the two native sides have
                // to answer the same name - this used to be
                // "getPendingNotificationAction", which that path never called,
                // so an Android tap parked here was never collected.
                "takePendingNotificationAction" -> {
                    result.success(pendingNotificationAction)
                    pendingNotificationAction = null
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // A tapped push notification can land here rather than on CopyActivity:
        // the backend does set an FCM clickAction of COPY_ACTION
        // (supabase/functions/send-clipboard-notification/index.ts), but that
        // routing does not always apply - image and file clips are never staged
        // for CopyActivity, and other platforms carry no clickAction at all.
        // FCM delivers the message's `data` entries as intent extras, so the
        // clip id arrives here; fetch and copy it through the existing
        // RLS-scoped path, once handleFcmLaunchIntent has established that a
        // push really named it.
        handleFcmLaunchIntent(intent)
    }

    /**
     * Copy the clip a push notification refers to, if this launch came from one.
     *
     * Any content in the extras is ignored - the push deliberately carries none.
     *
     * `clipboard_id` is resolved against Supabase under RLS, so it can only ever
     * name a row belonging to the signed-in user. That is not by itself enough:
     * this activity is exported (it is the LAUNCHER), so any installed app can
     * send an explicit intent with an id of its choosing and thereby pick WHICH
     * of the user's clips is decrypted onto the clipboard and WHEN - enough to
     * plant a stale wallet address before a paste, or to stage a clip and read
     * it back once the user's Back press hands focus to the caller. So the id is
     * accepted only when a push actually named it; see [PushRegistry].
     */
    private fun handleFcmLaunchIntent(launchIntent: Intent?) {
        val extras = launchIntent?.extras ?: return
        val clipboardId = extras.getString("clipboard_id") ?: return
        if (clipboardId.isEmpty() || clipboardId == lastHandledFcmClipboardId) return

        if (!PushRegistry.consume(this, clipboardId)) {
            Log.w(TAG, "⛔ Ignoring clipboard_id with no matching push")
            // Drop it so a resume loop does not retry the same rejected id.
            launchIntent.removeExtra("clipboard_id")
            return
        }

        lastHandledFcmClipboardId = clipboardId
        val contentType = extras.getString("content_type") ?: "text"
        val deviceType = extras.getString("device_type") ?: "Another device"

        Log.d(TAG, "📬 Launched from notification for clip $clipboardId")
        fetchAndCopyClipboardItem(clipboardId, contentType, deviceType)

        // Don't re-copy on the next resume (e.g. returning from the background).
        launchIntent.removeExtra("clipboard_id")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent) // Update the intent so Flutter can access it

        // A notification tapped while the app is already running arrives here.
        handleFcmLaunchIntent(intent)

        // ACTION_SEND is not handled here. receive_sharing_intent owns the
        // share sheet on both platforms; this used to catch it as well, so a
        // single share ran two paths - this one popping a device-picker dialog
        // and calling finish() out from under it, the plugin's sending the same
        // item again.
        if (intent.action == "com.ghostcopy.ghostcopy.COPY_ACTION") {
            // Handle notification tap while app is running
            handleCopyAction(intent)
        }
    }

    /**
     * MainActivity is exported (it is the LAUNCHER), so any installed app can
     * send it an explicit intent with an arbitrary action and extras - an
     * <intent-filter> is not required for explicit intents. This handler must
     * therefore treat every extra as untrusted.
     *
     * `clipboard_content` is deliberately NOT honoured here. Trusting it let a
     * malicious app write straight to the system clipboard (e.g. substituting a
     * wallet address) while the toast displayed an attacker-supplied device
     * name to make the swap look like a legitimate GhostCopy sync. The only
     * in-app caller, CopyActivity, forwards *just* clipboard_id for the
     * fetch-from-database path, so nothing legitimate needs the content extra.
     *
     * clipboard_id is resolved through the Flutter method channel against
     * Supabase under RLS, so it can only ever return a row belonging to the
     * signed-in user. That bounds the damage but does not remove it: choosing
     * WHICH of the user's own clips is copied, and WHEN, is itself the attack -
     * re-copying a stale wallet address just before the user pastes, or staging
     * a clip to read back once focus returns to the caller. Hence the token
     * check below rather than the `from_notification` boolean it replaced,
     * which any caller could set.
     */
    private fun handleCopyAction(intent: Intent) {
        // from_notification used to be the only gate, and it is an ordinary
        // boolean extra - any app could set it to true. CopyActivity runs in
        // this same process, so it can attach the real token instead.
        if (!IntentAuth.isTrusted(this, intent.getStringExtra(IntentAuth.EXTRA_TOKEN))) {
            Log.w(TAG, "⛔ Ignoring COPY_ACTION from an untrusted caller")
            return
        }

        val clipboardId = intent.getStringExtra("clipboard_id") ?: ""
        val contentType = intent.getStringExtra("content_type") ?: "text"
        val deviceType = intent.getStringExtra("device_type") ?: "Another device"

        if (intent.hasExtra("clipboard_content")) {
            Log.w(TAG, "⚠️ Ignoring clipboard_content on COPY_ACTION - untrusted source")
        }

        if (clipboardId.isNotEmpty()) {
            // Fetch content from the database using clipboard_id (RLS-scoped).
            Log.d(TAG, "📥 Fetching clipboard item $clipboardId from database")
            fetchAndCopyClipboardItem(clipboardId, contentType, deviceType)
        } else {
            Log.w(TAG, "⚠️ COPY_ACTION without a usable clipboard_id - ignoring")
        }
    }

    /**
     * Apply the user's screenshot-protection preference to this window.
     *
     * Read natively, from the store shared_preferences writes to, rather than
     * waiting for Dart to call back. FLAG_SECURE governs the Recents preview,
     * and Recents renders whatever the window looked like when it went to the
     * background - so a flag applied a second after launch, once Flutter had
     * booted, would already be too late for the first backgrounding. The window
     * has to be correct from the moment it exists.
     *
     * Defaults to false, matching ISettingsService: it is the user's own device,
     * and an ordinary Recents preview is theirs to have. Turning the cover on is
     * the deliberate act.
     *
     * The two defaults have to agree. This one decides what happens before Dart
     * has run, so a mismatch would blank a Recents card whose own toggle says it
     * should not be blanked.
     */
    private fun applyScreenshotProtection() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        // shared_preferences namespaces every key it writes with "flutter.".
        val enabled = prefs.getBoolean("flutter.$PREF_SCREENSHOT_PROTECTION", false)
        setSecureFlag(enabled)
    }

    private fun setSecureFlag(enabled: Boolean) {
        if (enabled) {
            window.setFlags(
                android.view.WindowManager.LayoutParams.FLAG_SECURE,
                android.view.WindowManager.LayoutParams.FLAG_SECURE
            )
        } else {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
        Log.d(TAG, "Screenshot protection ${if (enabled) "on" else "off"}")
    }

    /**
     * Create the channel FCM names in its manifest metadata.
     *
     * flutter_local_notifications creates this channel lazily, the first time
     * the app itself shows a local notification - which may never have happened
     * when a push arrives. A push naming a channel that does not exist is shown
     * on a default-importance fallback instead, with no heads-up banner. Channels
     * are persistent and re-creating one with the same id is a no-op, so this is
     * safe to run on every launch.
     */
    private fun ensureNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return

        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "GhostCopy Notifications",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Clips sent from your other devices"
            }
        )
        Log.d(TAG, "✅ Created notification channel $NOTIFICATION_CHANNEL_ID")
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

            // Park the action first. On a cold start the invokeMethod below is
            // delivered into the void - Dart registers its handler ~1.5s later,
            // and Flutter drops platform -> Dart messages that arrive with no
            // handler attached, without an error or a callback. Dart pulls the
            // parked copy when it builds the screen; the push below only
            // shortens the warm path.
            val parked = mapOf(
                "clipboardId" to clipboardId,
                "action" to action
            )
            pendingNotificationAction = parked

            // Invoke Flutter method to fetch clipboard item and perform action
            // Same method call that iOS uses via AppDelegate
            //
            // Cleared on a confirmed handling, and only then. Both transports
            // used to fire and the parked copy was never cleared, so when the
            // screen was later rebuilt - signing out and back in is enough -
            // its startup drain replayed a clip that had already been copied,
            // or opened a second share sheet for it. There is no de-duplication
            // on the Dart side to fall back on; an earlier comment here said
            // there was, and there is not.
            //
            // A dropped message never reaches success(), so the cold-start case
            // keeps its parked copy, which is the whole point of having one.
            channel.invokeMethod("handleNotificationAction", parked, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true && pendingNotificationAction === parked) {
                        pendingNotificationAction = null
                        Log.d(TAG, "Dart handled $clipboardId directly - parked copy dropped")
                    }
                }

                override fun error(code: String, message: String?, details: Any?) {
                    Log.w(TAG, "Dart failed to handle $clipboardId: $message")
                }

                override fun notImplemented() {}
            })
            Log.d(TAG, "✅ Queued+triggered $action action for clipboard item $clipboardId ($expectedContentType)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error fetching clipboard item: ${e.message}", e)
            Toast.makeText(this, "Failed to process item", Toast.LENGTH_SHORT).show()
        }
    }

}
