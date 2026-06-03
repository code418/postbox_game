package com.code418.postbox_game.car

import androidx.car.app.model.OnClickListener
import androidx.car.app.model.PaneTemplate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression guard for the Android Auto template-quota bug (the "This task
 *  cannot be completed while driving" crash on repeat claims).
 *
 *  The host counts a re-render against the five-templates-per-task quota unless
 *  it is a *refresh*: same template type, unchanged template title, same number
 *  of rows, and unchanged row titles. The quick-claim screen re-renders in place
 *  on every phase change, so if any of those invariants broke between phases the
 *  user would crash out after a couple of claims. These tests pin the invariants
 *  to [buildHomeTemplate] across one representative state per phase.
 *
 *  The car surface is deliberately a single status row + single Claim action —
 *  no points/streak/rank/leaderboard — so it stays a driving-relevant POI task.
 *  [singleClaimActionOnly] pins that minimalism. */
class HomeCarTemplateTest {

    private val noop = OnClickListener {}

    private fun state(status: String) = HomeUiState(statusMessage = status)

    /** One representative state per phase [HomeCarScreen] can render. */
    private val phaseStates = listOf(
        state("Tap to scan for nearby postboxes."),                       // Idle
        state("Scanning for postboxes nearby…"),                          // Working
        state("Claimed 2 postboxes (+8 pts)"),                            // Done / claimed
        state("No unclaimed postboxes in range. Try somewhere new!"),     // Done / empty
        state("You're travelling too fast — slow down before claiming again."), // Error
        state("Sign in on your phone to start claiming postboxes."),      // SignedOut
    )

    private fun build(s: HomeUiState): PaneTemplate =
        buildHomeTemplate(s, noop) as PaneTemplate

    @Test
    fun everyPhaseRendersAPaneTemplate() {
        phaseStates.forEach { s ->
            assertTrue(
                "every phase must render a PaneTemplate so updates count as refreshes",
                buildHomeTemplate(s, noop) is PaneTemplate,
            )
        }
    }

    @Test
    fun titleIsConstantAcrossPhases() {
        val titles = phaseStates.map { build(it).title?.toString() }.distinct()
        assertEquals(listOf("Postbox Quick Claim"), titles)
    }

    @Test
    fun rowCountIsConstantAndWithinPaneLimit() {
        val counts = phaseStates.map { build(it).pane.rows.size }.distinct()
        assertEquals("row count must be identical across phases", 1, counts.size)
        assertTrue(
            "pane must stay within the guaranteed 4-row limit",
            counts.first() <= 4,
        )
    }

    @Test
    fun rowTitlesAreConstantAcrossPhases() {
        val titleLists = phaseStates.map { s ->
            build(s).pane.rows.map { it.title?.toString() }
        }.distinct()
        assertEquals("row titles (and order) must be identical across phases", 1, titleLists.size)
    }

    @Test
    fun statusTextChangesBetweenPhases() {
        // The status row's secondary text is the only thing expected to differ
        // between e.g. Idle and Working.
        val idle = build(phaseStates[0]).pane.rows.first().texts.first().toString()
        val working = build(phaseStates[1]).pane.rows.first().texts.first().toString()
        assertNotEquals(idle, working)
    }

    @Test
    fun singleClaimActionOnly() {
        // Exactly one action (Claim) and one row (Status): no game/social
        // surfaces (points, streak, rank, leaderboard) on the driving screen.
        phaseStates.forEach { s ->
            val pane = build(s).pane
            assertEquals("car pane must carry a single status row", 1, pane.rows.size)
            assertEquals("car pane must carry a single Claim action", 1, pane.actions.size)
            assertEquals(
                "the only action must be the quick-claim",
                "Claim nearby postbox",
                pane.actions.first().title?.toString(),
            )
        }
    }
}
