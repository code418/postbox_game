package com.code418.postbox_game.car

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import androidx.car.app.CarContext
import androidx.core.content.ContextCompat
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import java.util.UUID
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Remote Config key mirroring `RemoteConfigService.keyMaintenanceMode`
 *  (lib/remote_config_service.dart). Pinned by
 *  test/cross_language_sync_test.dart. */
private const val KEY_MAINTENANCE_MODE = "maintenance_mode"

/** True when maintenance mode is on, best-effort.
 *
 *  `startScoring` has NO server-side maintenance check — the client guard is
 *  the only gate (see MaintenanceGuard's doc and the flushOfflineClaims
 *  comment explaining why only IT re-checks). The car surface had no gate at
 *  all, so a maintenance window opened to stop writes did not stop a car
 *  claiming into it.
 *
 *  FAIL-OPEN by design: the car runtime never loads the Dart engine, so
 *  nothing in this process calls setDefaults/fetchAndActivate. This reads
 *  whatever the phone app last ACTIVATED (Remote Config persists activated
 *  values per app, not per process); if the phone has never fetched, it
 *  returns false and behaviour is exactly what it was before. Never worse,
 *  usually better. */
private fun maintenanceModeOn(): Boolean = try {
    FirebaseRemoteConfig.getInstance().getBoolean(KEY_MAINTENANCE_MODE)
} catch (e: Exception) {
    false
}

/** Runs a single quick-claim cycle for Android Auto.
 *
 *  1. Verifies the user is signed in (no login UI in the car).
 *  2. Fetches one fresh location fix via `FusedLocationProviderClient`.
 *  3. Calls the `startScoring` Cloud Function with `{ lat, lng }`.
 *  4. Maps the response (or HttpsError) to an [Outcome] for the screen. */
class ClaimAction(private val carContext: CarContext) {

    sealed interface Outcome {
        data class Claimed(val count: Int, val points: Int) : Outcome
        data object Empty : Outcome
        data object AlreadyClaimedToday : Outcome
        data object TooFast : Outcome
        data object NotSignedIn : Outcome
        data object UnderMaintenance : Outcome
        data class Error(val display: String) : Outcome
    }

    suspend fun run(): Outcome {
        if (FirebaseAuth.getInstance().currentUser == null) return Outcome.NotSignedIn
        if (maintenanceModeOn()) return Outcome.UnderMaintenance

        val fineGranted = ContextCompat.checkSelfPermission(
            carContext, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            carContext, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineGranted && !coarseGranted) {
            return Outcome.Error("Location permission needed — open the phone app to grant it.")
        }

        val location = try {
            fetchLocation()
        } catch (e: Exception) {
            return Outcome.Error("Couldn't get your location. Try again in a moment.")
        } ?: return Outcome.Error("No GPS fix yet. Move to open sky and retry.")

        return try {
            val payload = hashMapOf(
                "lat" to location.first,
                "lng" to location.second,
                // One id per logical claim attempt. startScoring is the app's
                // only non-idempotent write and this id is the ONLY thing that
                // makes it safe to repeat: the server stores the response
                // against it and replays it (functions/src/_attempts.ts).
                // Without one, a dropped RESPONSE — routine in a car, which
                // drives through tunnels and notspots — recorded the claim
                // while the screen said "Claim failed", and the retry landed
                // in the already-claimed fast path. Points earned, never seen.
                // Matches the phone sheet and the Wear page.
                "attemptId" to UUID.randomUUID().toString(),
                // Client wall-clock for the shadow-mode out-of-window anomaly
                // signal. The car surface previously sent none, so its claims
                // were invisible to that detector. (deviceIdHash stays absent:
                // it lives in the Dart install store and the car runtime never
                // loads the Dart engine.)
                "clientTsMs" to System.currentTimeMillis(),
            )
            // Region-pinned to match lib/firebase_functions_eu.dart — every
            // function deploys to europe-west2 only; the no-arg getInstance()
            // targets us-central1, where nothing is listening. Guarded by
            // test/firebase_functions_region_test.dart (Kotlin scan).
            val result = FirebaseFunctions.getInstance("europe-west2")
                .getHttpsCallable("startScoring")
                .call(payload)
                .await()
            @Suppress("UNCHECKED_CAST")
            val data = result.data as? Map<String, Any?> ?: return Outcome.Error("Unexpected server response.")
            val found = data["found"] as? Boolean ?: false
            val claimed = (data["claimed"] as? Number)?.toInt() ?: 0
            val points = (data["points"] as? Number)?.toInt() ?: 0
            val allClaimedToday = data["allClaimedToday"] as? Boolean ?: false
            when {
                claimed > 0 -> Outcome.Claimed(claimed, points)
                !found -> Outcome.Empty
                allClaimedToday -> Outcome.AlreadyClaimedToday
                else -> Outcome.Empty
            }
        } catch (e: FirebaseFunctionsException) {
            when (e.code) {
                FirebaseFunctionsException.Code.FAILED_PRECONDITION -> Outcome.TooFast
                FirebaseFunctionsException.Code.UNAUTHENTICATED -> Outcome.NotSignedIn
                else -> Outcome.Error(e.message ?: "Claim failed. Try again.")
            }
        } catch (e: Exception) {
            Outcome.Error("Claim failed. Try again.")
        }
    }

    @SuppressLint("MissingPermission") // Checked above before invocation.
    private suspend fun fetchLocation(): Pair<Double, Double>? {
        val client = LocationServices.getFusedLocationProviderClient(carContext)
        val request = CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
            .setMaxUpdateAgeMillis(30_000)
            .build()
        return suspendCancellableCoroutine { cont ->
            client.getCurrentLocation(request, null)
                .addOnSuccessListener { loc ->
                    cont.resume(loc?.let { it.latitude to it.longitude })
                }
                .addOnFailureListener { err ->
                    cont.resumeWithException(err)
                }
        }
    }
}

/** Suspend-wrapper for Play Services `Task`.  Kept private to avoid a
 *  kotlinx-coroutines-play-services dependency. */
private suspend fun <T> com.google.android.gms.tasks.Task<T>.await(): T =
    suspendCancellableCoroutine { cont ->
        addOnSuccessListener { cont.resume(it) }
        addOnFailureListener { cont.resumeWithException(it) }
        addOnCanceledListener { cont.cancel() }
    }
