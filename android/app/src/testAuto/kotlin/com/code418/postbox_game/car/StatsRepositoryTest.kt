package com.code418.postbox_game.car

import org.junit.Assert.assertEquals
import org.junit.Test

/** Pins the cross-language streak-freshness rule on the Kotlin/Android-Auto
 *  path. The Dart side is covered by lib/streak_service.dart tests; this
 *  test catches the Kotlin re-implementation drifting away from it (the
 *  car runtime can't share Dart code — see the "native-edge test blind
 *  spot" deferred-followups note for why this matters).
 *
 *  Boundaries pinned:
 *    - stored streak 0 → 0 regardless of date
 *    - missing lastClaimDate → 0 (defensive: can't verify freshness)
 *    - lastClaimDate == today → streak (active today)
 *    - lastClaimDate == yesterday → streak (still alive)
 *    - any older lastClaimDate → 0 (broken streak)
 */
class StatsRepositoryTest {

    private val today = "2026-05-27"
    private val yesterday = "2026-05-26"

    @Test
    fun storedZeroAlwaysReturnsZero() {
        assertEquals(0, freshStreak(0, today, today, yesterday))
        assertEquals(0, freshStreak(0, null, today, yesterday))
        assertEquals(0, freshStreak(0, "2024-01-01", today, yesterday))
    }

    @Test
    fun nullLastClaimReturnsZero() {
        assertEquals(0, freshStreak(7, null, today, yesterday))
    }

    @Test
    fun lastClaimTodayReturnsStored() {
        assertEquals(7, freshStreak(7, today, today, yesterday))
    }

    @Test
    fun lastClaimYesterdayReturnsStored() {
        assertEquals(4, freshStreak(4, yesterday, today, yesterday))
    }

    @Test
    fun olderLastClaimReturnsZero() {
        assertEquals(0, freshStreak(9, "2026-05-24", today, yesterday))
        assertEquals(0, freshStreak(9, "2024-06-01", today, yesterday))
    }
}
