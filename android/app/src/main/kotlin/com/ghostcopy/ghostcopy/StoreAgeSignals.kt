package com.ghostcopy.ghostcopy

import android.app.Activity
import com.google.android.play.agesignals.AgeSignalsAccessRequest
import com.google.android.play.agesignals.AgeSignalsManagerFactory
import com.google.android.play.agesignals.AgeSignalsRequest
import com.google.android.play.agesignals.AgeSignalsResult
import com.google.android.play.agesignals.model.AgeSignalsStatus
import com.google.android.play.agesignals.model.SignificantChangeStatus
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Google Play Age Signals (com.google.android.play:age-signals 0.0.4) for
 * lib/services/store_age_signal_service.dart. Mirrors StoreAgeSignals in
 * ios/Runner/StoreAgeSignals.swift.
 *
 * 0.0.4 is two calls: requestAgeSignalsAccess() (may show Play's sharing
 * prompt, or in regulated US states send the user to Play to verify), then
 * checkAgeSignals() only after SHARED. userStatus and its SUPERVISED_* values
 * were removed in 0.0.4; supervision now shows as significantChangeStatus.
 *
 * The answer goes to Dart and nowhere else: Play's terms allow it only for
 * age-appropriate experiences in this app. Nothing is logged or stored here.
 * Any failure (APP_NOT_OWNED for a sideloaded build, no Play Store, network)
 * answers "not shared", which keeps the self-declared setup.
 */
object StoreAgeSignals {
    private const val CHANNEL = "com.ghostcopy/store_age"

    /**
     * Play granted access (SHARED) in this process. Later calls - "Check
     * again", the significant-change check - go straight to checkAgeSignals()
     * for a fresh status instead of asking for access again, which would
     * re-prompt or re-open Play's verification screen on every tap. Process
     * memory only: whether to share is the user's choice in Play each launch.
     */
    @Volatile
    private var accessGranted = false

    fun attach(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestAgeSignal" -> check(activity) { signals ->
                    result.success(signals?.let(::describe) ?: mapOf("shared" to false))
                }
                // Play has no in-app request: the significant change is
                // declared in Play Console and the parent approves it in
                // Family Link. This reports where that approval stands.
                "significantChange" -> check(activity) { signals ->
                    result.success(
                        when (signals?.significantChangeStatus()) {
                            SignificantChangeStatus.APPROVED -> "approved"
                            SignificantChangeStatus.PENDING -> "pending"
                            SignificantChangeStatus.DECLINED -> "declined"
                            else -> "notRequired"
                        },
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Calls [done] once, on the main thread, with null when not shared. */
    private fun check(activity: Activity, done: (AgeSignalsResult?) -> Unit) {
        val manager = try {
            AgeSignalsManagerFactory.create(activity.applicationContext)
        } catch (_: Exception) {
            done(null)
            return
        }
        fun signals() {
            manager.checkAgeSignals(AgeSignalsRequest.builder().build())
                .addOnSuccessListener { done(it) }
                .addOnFailureListener { done(null) }
        }
        if (accessGranted) {
            signals()
            return
        }
        manager.requestAgeSignalsAccess(AgeSignalsAccessRequest.builder().setActivity(activity).build())
            .addOnSuccessListener { access ->
                if (access.ageSignalsStatus() != AgeSignalsStatus.SHARED) {
                    done(null)
                    return@addOnSuccessListener
                }
                accessGranted = true
                signals()
            }
            .addOnFailureListener { done(null) }
    }

    private fun describe(signals: AgeSignalsResult): Map<String, Any?> = mapOf(
        "shared" to true,
        "store" to "google_play",
        "ageLower" to signals.ageLower(),
        "ageUpper" to signals.ageUpper(),
        // Only for supervised users; Play allows keeping it server-side to
        // match its revoked-approval report, and for nothing else.
        "storeRef" to signals.installId(),
        "significantChange" to when (signals.significantChangeStatus()) {
            SignificantChangeStatus.PENDING -> "pending"
            SignificantChangeStatus.DECLINED -> "declined"
            SignificantChangeStatus.APPROVED -> "approved"
            else -> null
        },
    )
}
