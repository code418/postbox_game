package com.code418.postbox_game.wear

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * Pure presentation logic for the Wear tile and complications.
 *
 * Deliberately free of Android imports so it can be unit-tested on the JVM
 * (`src/testWear`). The Wear surfaces have no other automated coverage — the
 * same reasoning behind `wearClaimErrorMessage` and the shared quiz helpers on
 * the Dart side.
 *
 * The freshness rules here MIRROR Dart: `freshStreak` in
 * `lib/streak_service.dart` and the `dailyDate`/`lastClaimDate` fallback in
 * `HomeWidgetService.refresh`. They have to be applied a second time, natively,
 * because `HomeWidgetService` date-checks only at WRITE time: the tile renders
 * whenever the system asks, which on a watch the app hasn't been opened on
 * since yesterday is long after that write.
 */
data class WearStats(
    val signedIn: Boolean,
    val streak: Int,
    val todayPoints: Int,
    val lifetimePoints: Int,
    val boxesFound: Int,
)

/** The game's day boundary. The server writes every date in this zone. */
val LONDON: ZoneId = ZoneId.of("Europe/London")

/** Today in Europe/London as `YYYY-MM-DD`, matching the stored date strings. */
fun londonToday(now: Instant = Instant.now(), zone: ZoneId = LONDON): String =
    LocalDate.ofInstant(now, zone).toString()

/** The day before [today] (`YYYY-MM-DD` in, `YYYY-MM-DD` out). */
fun londonYesterday(today: String): String =
    LocalDate.parse(today).minusDays(1).toString()

/**
 * Blank is how a missing date reaches us: `HomeWidgetService` writes `""`
 * rather than omitting the key, because the plugin's store has no null.
 */
private fun String?.orNullIfBlank(): String? = if (isNullOrBlank()) null else this

/**
 * Today's points, or 0 if the stored value belongs to an earlier day.
 *
 * `dailyPoints` is never reset server-side (see startScoring's lifetime
 * transaction), so the stored number reflects whichever day's claim last
 * touched it. `dailyDate` is written in that same transaction; `lastClaimDate`
 * comes from a separate streak transaction, so it is only the fallback for
 * accounts that last claimed before `dailyDate` existed.
 */
fun freshTodayPoints(
    stored: Int,
    dailyDate: String?,
    lastClaimDate: String?,
    today: String,
): Int {
    val daily = dailyDate.orNullIfBlank()
    val last = lastClaimDate.orNullIfBlank()
    val fresh = if (daily != null) daily == today else last == today
    return if (fresh) stored else 0
}

/**
 * The streak to show, or 0 once it is broken.
 *
 * The server only rewrites `streak` on a claim, so a user who missed yesterday
 * would otherwise keep seeing their old streak on the watch face until they
 * claimed again — the tile would be quietly lying about the thing it exists to
 * show.
 */
fun freshStreak(
    stored: Int,
    lastClaimDate: String?,
    today: String,
    yesterday: String,
): Int {
    if (stored <= 0) return 0
    val last = lastClaimDate.orNullIfBlank() ?: return 0
    return if (last == today || last == yesterday) stored else 0
}

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
