package com.code418.postbox_game.car

import com.google.firebase.firestore.FirebaseFirestore
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** Firestore reads that back the Android Auto stats pane and leaderboard
 *  screen. Kept off the Flutter side because the car runtime never loads the
 *  Dart engine. */
object StatsRepository {

    data class UserStats(
        val lifetimePoints: Int,
        val uniquePostboxesClaimed: Int,
        val streak: Int,
        val displayName: String?,
    )

    data class LeaderboardEntry(
        val uid: String,
        val displayName: String,
        val points: Int,
    )

    private val db get() = FirebaseFirestore.getInstance()

    /** Emits the latest `users/{uid}` stats. Snapshot listener so the pane
     *  refreshes the moment `startScoring` writes new lifetime totals. */
    fun observeUserStats(uid: String): Flow<UserStats> = callbackFlow {
        val reg = db.collection("users").document(uid)
            .addSnapshotListener { snap, err ->
                if (err != null || snap == null || !snap.exists()) return@addSnapshotListener
                trySend(
                    UserStats(
                        // The user doc stores the cumulative total under
                        // `lifetimePoints` (see startScoring's lifetime tx);
                        // there is no `totalPoints` field on users/{uid}, so
                        // the previous read always fell back to 0.
                        lifetimePoints = (snap.get("lifetimePoints") as? Number)?.toInt() ?: 0,
                        uniquePostboxesClaimed = (snap.get("uniquePostboxesClaimed") as? Number)?.toInt() ?: 0,
                        streak = (snap.get("streak") as? Number)?.toInt() ?: 0,
                        displayName = snap.getString("displayName"),
                    )
                )
            }
        awaitClose { reg.remove() }
    }

    /** One-shot read of `leaderboards/daily.entries`. Capped at 20 so we have
     *  enough rows to compute "your rank" while only rendering the top few.
     *
     *  Discards entries when the stored periodKey doesn't match today's
     *  London date — without this, between midnight London and the moment
     *  newDayScoreboard runs, the car would show yesterday's leaderboard
     *  (and the user's "rank" would be computed against yesterday's pool).
     *  Mirrors the staleness check the Flutter LeaderboardList performs. */
    suspend fun fetchDailyLeaderboard(): List<LeaderboardEntry> {
        return try {
            val snap = suspendCancellableCoroutine<com.google.firebase.firestore.DocumentSnapshot> { cont ->
                db.collection("leaderboards").document("daily").get()
                    .addOnSuccessListener { cont.resume(it) }
                    .addOnFailureListener { cont.cancel(it) }
            }
            val storedPeriodKey = snap.getString("periodKey")
            if (storedPeriodKey != null && storedPeriodKey != londonDateToday()) {
                return emptyList()
            }
            @Suppress("UNCHECKED_CAST")
            val raw = snap.get("entries") as? List<Map<String, Any?>> ?: emptyList()
            raw.take(20).mapNotNull { e ->
                val uid = e["uid"] as? String ?: return@mapNotNull null
                LeaderboardEntry(
                    uid = uid,
                    displayName = (e["displayName"] as? String) ?: "Anonymous",
                    points = (e["points"] as? Number)?.toInt() ?: 0,
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** YYYY-MM-DD in Europe/London — matches getTodayLondon() in
     *  functions/src/_dateUtils.ts and todayLondon() in lib/london_date.dart,
     *  which are the values written into `periodKey` for the daily board. */
    private fun londonDateToday(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.UK)
        fmt.timeZone = TimeZone.getTimeZone("Europe/London")
        return fmt.format(java.util.Date())
    }
}
