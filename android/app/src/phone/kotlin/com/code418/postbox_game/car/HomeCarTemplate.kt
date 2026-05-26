package com.code418.postbox_game.car

import androidx.car.app.model.Action
import androidx.car.app.model.CarColor
import androidx.car.app.model.OnClickListener
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template

/** Immutable view-state for the Android Auto home pane. Everything the pane
 *  shows is derived from this; [HomeCarScreen.onGetTemplate] recomputes it on
 *  every refresh and hands it to [buildHomeTemplate]. */
data class HomeUiState(
    val statusMessage: String,
    val lifetimePoints: Int?,
    val uniqueBoxes: Int?,
    val streakLabel: String,
    val rankLabel: String,
)

/** Builds the Android Auto home screen's template.
 *
 *  CRITICAL — Android Auto template quota. The host allows a maximum of **five
 *  templates per task** and only treats a new template as a free *refresh* when
 *  it is the SAME type with an unchanged template title, the same number of
 *  rows, and unchanged row titles (only a row's secondary text may change). The
 *  quick-claim flow lives on a single [HomeCarScreen] updated via `invalidate()`
 *  and never navigates away, so if the template type — or its title / row
 *  structure — changed between phases, each change would burn a step and the
 *  user would hit *"This task cannot be completed while driving"* after a couple
 *  of claims. We therefore ALWAYS return a [PaneTemplate] with a constant title,
 *  a constant set of row titles, and constant actions; phase changes only ever
 *  alter the rows' secondary text. Keep it that way (see HomeCarTemplateTest).
 *
 *  Pure and Context-free so it can be unit-tested without Firebase or
 *  Robolectric. */
fun buildHomeTemplate(
    state: HomeUiState,
    onClaim: OnClickListener,
    onLeaderboard: OnClickListener,
): Template {
    val pane = Pane.Builder()
        .addRow(
            Row.Builder()
                .setTitle("Status")
                .addText(state.statusMessage)
                .build()
        )
        .addRow(
            Row.Builder()
                .setTitle("Total points / boxes")
                .addText(pointsAndBoxesLabel(state.lifetimePoints, state.uniqueBoxes))
                .build()
        )
        .addRow(
            Row.Builder()
                .setTitle("Daily streak")
                .addText(state.streakLabel)
                .build()
        )
        .addRow(
            Row.Builder()
                .setTitle("Today's rank")
                .addText(state.rankLabel)
                .build()
        )
        .addAction(
            Action.Builder()
                .setTitle("Claim nearby postbox")
                .setBackgroundColor(CarColor.RED)
                .setOnClickListener(onClaim)
                .build()
        )
        .addAction(
            Action.Builder()
                .setTitle("Leaderboard")
                .setOnClickListener(onLeaderboard)
                .build()
        )
        .build()

    return PaneTemplate.Builder(pane)
        .setTitle("Postbox Quick Claim")
        .setHeaderAction(Action.APP_ICON)
        .build()
}

private fun pointsAndBoxesLabel(points: Int?, boxes: Int?): String {
    val p = points?.toString() ?: "—"
    val b = boxes?.toString() ?: "—"
    return "$p pts · $b boxes"
}
