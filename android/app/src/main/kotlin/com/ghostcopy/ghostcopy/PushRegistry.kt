package com.ghostcopy.ghostcopy

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Record of clip ids a push actually arrived for.
 *
 * MainActivity is exported because it is the LAUNCHER, so any installed app can
 * send it an explicit intent carrying whatever `clipboard_id` it likes. That id
 * is resolved under RLS, so it can only ever name one of the signed-in user's
 * own clips - but it still lets a third-party app choose WHICH of the user's
 * clips is decrypted onto the system clipboard, and WHEN. That is enough to
 * plant a stale wallet address just before the user pastes, or to stage a clip
 * and read it back after the user's next Back press returns focus to the
 * caller.
 *
 * [IntentAuth] cannot solve this one: FCM hands the push's `data` entries to
 * the launcher as intent extras, and there is no way to attach a secret to an
 * intent the FCM SDK builds. So instead of authenticating the caller, this
 * authenticates the CLAIM: a genuine notification tap is always preceded by a
 * push, and a push is something only the backend can cause. An id that no push
 * ever mentioned is refused.
 *
 * Written from both delivery paths, because which one runs depends on app state
 * and on which MESSAGING_EVENT service Android picked:
 *   * [FirebaseMessagingService.onMessageReceived] - foreground deliveries
 *   * the Dart background isolate (`_recordIncomingPush` in lib/main.dart) -
 *     background and terminated deliveries
 * Recording twice is harmless; the store is keyed by id.
 *
 * Lives in filesDir as JSON, which is the same app-private directory and the
 * same interop pattern `pending_copy.json` already uses between Dart and Kotlin.
 */
object PushRegistry {
    /**
     * How long a recorded push stays redeemable.
     *
     * Generous on purpose: a notification sits in the shade until the user
     * chooses to deal with it, and expiring an id the user can still see would
     * turn a tap into a silent no-op. A day still bounds an attacker to the
     * handful of clips the user genuinely received pushes for recently, rather
     * than every row in their history.
     */
    private const val TTL_MS = 24L * 60 * 60 * 1000

    /** Keeps the file small; far more than a day's worth of clips in practice. */
    private const val MAX_ENTRIES = 50

    private const val FILE = "pending_push.json"
    private const val TAG = "PushRegistry"

    /** Note that a push naming [clipboardId] arrived. */
    @Synchronized
    fun record(context: Context, clipboardId: String) {
        if (clipboardId.isEmpty()) return

        try {
            val entries = read(context)
            entries.put(clipboardId, System.currentTimeMillis())
            write(context, entries)
            Log.d(TAG, "Recorded push for $clipboardId")
        } catch (e: Exception) {
            // Best effort. A failure here costs the user one silent notification
            // tap, which is strictly better than copying an unverified clip.
            Log.w(TAG, "Could not record push: ${e.message}")
        }
    }

    /**
     * True when a push really did arrive for [clipboardId], consuming the record.
     *
     * Consuming it means a replayed intent cannot copy the same clip twice.
     */
    @Synchronized
    fun consume(context: Context, clipboardId: String): Boolean {
        if (clipboardId.isEmpty()) return false

        return try {
            val entries = read(context)
            if (!entries.has(clipboardId)) {
                Log.w(TAG, "Refused $clipboardId - no push recorded for it")
                return false
            }
            entries.remove(clipboardId)
            write(context, entries)
            true
        } catch (e: Exception) {
            Log.w(TAG, "Could not consume push record: ${e.message}")
            false
        }
    }

    /** Entries that are still within [TTL_MS], newest kept when over capacity. */
    private fun read(context: Context): JSONObject {
        val file = File(context.filesDir, FILE)
        if (!file.exists()) return JSONObject()

        val raw = JSONObject(file.readText())
        val cutoff = System.currentTimeMillis() - TTL_MS
        val fresh = JSONObject()

        for (key in raw.keys()) {
            val at = raw.optLong(key, 0)
            if (at >= cutoff) fresh.put(key, at)
        }

        if (fresh.length() <= MAX_ENTRIES) return fresh

        // Over capacity: keep the newest MAX_ENTRIES.
        val newest = fresh.keys()
            .asSequence()
            .sortedByDescending { fresh.optLong(it, 0) }
            .take(MAX_ENTRIES)
        val capped = JSONObject()
        for (key in newest) capped.put(key, fresh.optLong(key, 0))
        return capped
    }

    private fun write(context: Context, entries: JSONObject) {
        File(context.filesDir, FILE).writeText(entries.toString())
    }
}
