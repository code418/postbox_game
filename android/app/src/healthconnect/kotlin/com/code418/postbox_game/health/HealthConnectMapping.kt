package com.code418.postbox_game.health

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Metadata

/**
 * Pure mapping between Health Connect values and the MethodChannel wire format
 * for workout claims. No Android framework calls, so it is unit-tested on the
 * JVM (src/testHealthconnect).
 *
 * The eligible exercise-type NAMES are mirrored in
 * lib/activity/activity_helpers.dart and functions/src/_activityConfig.ts
 * (ELIGIBLE_EXERCISE_TYPES); test/cross_language_sync_test.dart pins all three.
 */
object HealthConnectMapping {
    const val CHANNEL = "com.code418.postbox_game/health_connect"
    const val PROVIDER_PACKAGE = "com.google.android.apps.healthdata"

    /** Read-only: sessions and their routes. Nothing is ever written. */
    const val PERMISSION_READ_EXERCISE = "android.permission.health.READ_EXERCISE"
    /** Note the plural (the write permission is singular). */
    const val PERMISSION_READ_EXERCISE_ROUTES = "android.permission.health.READ_EXERCISE_ROUTES"
    val PERMISSIONS: Set<String> = setOf(PERMISSION_READ_EXERCISE, PERMISSION_READ_EXERCISE_ROUTES)

    /** On-foot outdoor activities only. Treadmill running has no route and
     *  cycling is deliberately excluded (game design: walking pace). */
    val ELIGIBLE_EXERCISE_TYPES: Map<Int, String> = mapOf(
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "walking",
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING to "running",
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "hiking",
    )

    fun exerciseTypeName(type: Int): String? = ELIGIBLE_EXERCISE_TYPES[type]

    fun recordingMethodName(method: Int): String = when (method) {
        Metadata.RECORDING_METHOD_ACTIVELY_RECORDED -> "active"
        Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED -> "automatic"
        Metadata.RECORDING_METHOD_MANUAL_ENTRY -> "manual"
        else -> "unknown"
    }

    /** Wire status for Health Connect availability. Below Android 9 the
     *  Health Connect app cannot run at all. */
    fun statusName(sdkInt: Int, sdkStatus: Int, available: Int, updateRequired: Int): String = when {
        sdkInt < 28 -> "unsupported_os"
        sdkStatus == available -> "available"
        sdkStatus == updateRequired -> "update_required"
        else -> "not_installed"
    }

    /** One GPS fix, framework-free. */
    data class RouteFix(val tMs: Long, val lat: Double, val lng: Double, val accuracyM: Double?)

    /** Parallel arrays for the StandardMessageCodec (LongArray → Int64List,
     *  DoubleArray → Float64List). Unknown accuracy is NaN. */
    class EncodedRoute(val t: LongArray, val lat: DoubleArray, val lng: DoubleArray, val acc: DoubleArray) {
        fun toMap(): Map<String, Any> = mapOf("status" to "data", "t" to t, "lat" to lat, "lng" to lng, "acc" to acc)
    }

    /** Sort by time and drop non-finite / out-of-range fixes. */
    fun encodeRoute(fixes: List<RouteFix>): EncodedRoute {
        val ok = fixes
            .filter { it.lat.isFinite() && it.lng.isFinite() && it.lat in -90.0..90.0 && it.lng in -180.0..180.0 }
            .sortedBy { it.tMs }
        return EncodedRoute(
            t = LongArray(ok.size) { ok[it].tMs },
            lat = DoubleArray(ok.size) { ok[it].lat },
            lng = DoubleArray(ok.size) { ok[it].lng },
            acc = DoubleArray(ok.size) { ok[it].accuracyM?.takeIf { a -> a.isFinite() } ?: Double.NaN },
        )
    }
}
