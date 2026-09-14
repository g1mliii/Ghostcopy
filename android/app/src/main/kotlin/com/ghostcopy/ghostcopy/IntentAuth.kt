package com.ghostcopy.ghostcopy

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

/**
 * Caller authentication for intents delivered to MainActivity.
 *
 * MainActivity is exported because it is the LAUNCHER activity, and an exported
 * component accepts *explicit* intents from any app regardless of what
 * <intent-filter>s it declares. Any installed app can therefore deliver
 * WIDGET_ITEM_CLICK with arbitrary extras. Since those handlers write to the
 * system clipboard, an unauthenticated caller could substitute content (a
 * wallet address, a shell command) that the user then pastes, with the toast
 * naming an attacker-supplied device to make it look like a genuine sync.
 *
 * Activity.getReferrer() is unreliable here - it can be null for
 * PendingIntent-delivered intents - so instead we carry a token that only this
 * app can read. It lives in app-private SharedPreferences, which other apps
 * cannot access under the Android sandbox, and is minted once per install.
 */
object IntentAuth {
    const val EXTRA_TOKEN = "ghostcopy_intent_token"

    private const val PREFS = "ghostcopy_intent_auth"
    private const val KEY = "token"

    @Volatile private var cached: String? = null

    /** Returns this install's token, creating it on first use. */
    fun token(context: Context): String {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            var value = prefs.getString(KEY, null)
            if (value == null) {
                val bytes = ByteArray(32)
                SecureRandom().nextBytes(bytes)
                value = Base64.encodeToString(bytes, Base64.NO_WRAP)
                prefs.edit().putString(KEY, value).apply()
            }
            cached = value
            return value
        }
    }

    /** True when the intent carries this install's token. */
    fun isTrusted(context: Context, provided: String?): Boolean {
        if (provided == null) return false
        val expected = token(context)
        // Length-independent constant-time-ish comparison.
        if (provided.length != expected.length) return false
        var diff = 0
        for (i in expected.indices) {
            diff = diff or (expected[i].code xor provided[i].code)
        }
        return diff == 0
    }
}
