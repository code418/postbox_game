package com.code418.postbox_game.wear

/**
 * Pure presentation logic for the Wear tile and complications.
 *
 * Deliberately free of Android imports so it can be unit-tested on the JVM
 * (`src/testWear`). The Wear surfaces have no other automated coverage — the
 * same reasoning behind `wearClaimErrorMessage` and the shared quiz helpers on
 * the Dart side.
 *
 * The London-date freshness rules (`freshStreak`, `freshTodayPoints`, ...)
 * live in `WidgetFreshness.kt` in the main source set, shared with the phone
 * home-screen widget, which needs exactly the same re-check.
 */
data class WearStats(
    val signedIn: Boolean,
    val streak: Int,
    val todayPoints: Int,
    val lifetimePoints: Int,
    val boxesFound: Int,
)

/**
 * The next streak length worth aiming at, used as the maximum of the
 * RANGED_VALUE complication so the arc means something.
 */
fun nextStreakMilestone(streak: Int): Int {
    for (milestone in intArrayOf(7, 30, 100, 365)) {
        if (streak < milestone) return milestone
    }
    // Past a year, keep the arc moving in further years rather than pinning
    // it full forever.
    return ((streak / 365) + 1) * 365
}

/** e.g. "5 day streak", "1 day streak", "No streak". */
fun streakLabel(streak: Int): String = when {
    streak <= 0 -> "No streak"
    streak == 1 -> "1 day streak"
    else -> "$streak day streak"
}

/**
 * Points for a tile or complication slot. Complication short text is capped at
 * 7 characters by the system and a tile has little room either, so large
 * totals are abbreviated rather than truncated mid-number.
 */
fun pointsLabel(points: Int): String = when {
    points < 10_000 -> points.toString()
    points < 1_000_000 -> {
        val tenths = points / 100
        if (tenths % 10 == 0) "${tenths / 10}k" else "${tenths / 10}.${tenths % 10}k"
    }
    else -> "${points / 1_000_000}M"
}
