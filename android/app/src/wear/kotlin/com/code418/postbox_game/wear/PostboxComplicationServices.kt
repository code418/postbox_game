package com.code418.postbox_game.wear

import android.app.PendingIntent
import android.content.Context
import android.net.Uri
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceService
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import com.code418.postbox_game.MainActivity
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * Shared plumbing for the watch-face complications.
 *
 * Like the tile, these render from [WearPrefs] alone — the watch face asks for
 * data on its own schedule, often while the app is not running, so anything
 * needing auth or network would simply be blank.
 */
abstract class PostboxComplicationService : ComplicationDataSourceService() {

    /** `postbox://claim?source=complication` — see `lib/deep_links.dart`. */
    protected fun tapAction(): PendingIntent =
        HomeWidgetLaunchIntent.getActivity(
            this,
            MainActivity::class.java,
            Uri.parse(DEEP_LINK),
        )

    protected fun text(value: String): PlainComplicationText =
        PlainComplicationText.Builder(value).build()

    companion object {
        const val DEEP_LINK = "postbox://claim?source=complication"

        /**
         * Shown when no one is signed in.
         *
         * An em dash rather than `0`, which on a watch face would read as a
         * genuine score of zero — the user would think they'd lost their
         * points rather than that they need to sign in.
         */
        const val SIGNED_OUT_TEXT = "—"
    }
}

/**
 * Current daily-claim streak.
 *
 * Offers RANGED_VALUE as well as SHORT_TEXT so watch faces with an arc slot can
 * show progress towards the next milestone ([nextStreakMilestone]) — which is
 * always strictly ahead of the current streak, so the arc is never stuck full.
 */
class StreakComplicationService : PostboxComplicationService() {

    override fun onComplicationRequest(
        request: ComplicationRequest,
        listener: ComplicationRequestListener,
    ) {
        val stats = WearPrefs.read(this)
        listener.onComplicationData(build(request.complicationType, stats))
    }

    /**
     * Sample data for the complication picker. [getPreviewData] is abstract and
     * returning null hides the source (or shows it blank), which is a
     * straightforward Wear quality fail.
     */
    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        build(
            type,
            WearStats(
                signedIn = true,
                streak = 5,
                todayPoints = 12,
                lifetimePoints = 480,
                boxesFound = 96,
            ),
        )

    private fun build(type: ComplicationType, stats: WearStats): ComplicationData? {
        val label = if (stats.signedIn) stats.streak.toString() else SIGNED_OUT_TEXT
        return when (type) {
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(
                text(label),
                text(streakLabel(stats.streak)),
            )
                .setTitle(text("streak"))
                .setTapAction(tapAction())
                .build()

            ComplicationType.RANGED_VALUE -> RangedValueComplicationData.Builder(
                value = stats.streak.toFloat(),
                min = 0f,
                max = nextStreakMilestone(stats.streak).toFloat(),
                contentDescription = text(streakLabel(stats.streak)),
            )
                .setText(text(label))
                .setTitle(text("streak"))
                .setTapAction(tapAction())
                .build()

            else -> null
        }
    }
}

/**
 * Points claimed today.
 *
 * SHORT_TEXT only: there is no daily target in this game, so a RANGED_VALUE arc
 * would need an invented maximum — worse than not offering the type.
 */
class TodayPointsComplicationService : PostboxComplicationService() {

    override fun onComplicationRequest(
        request: ComplicationRequest,
        listener: ComplicationRequestListener,
    ) {
        val stats = WearPrefs.read(this)
        listener.onComplicationData(build(request.complicationType, stats))
    }

    override fun getPreviewData(type: ComplicationType): ComplicationData? =
        build(
            type,
            WearStats(
                signedIn = true,
                streak = 5,
                todayPoints = 12,
                lifetimePoints = 480,
                boxesFound = 96,
            ),
        )

    private fun build(type: ComplicationType, stats: WearStats): ComplicationData? {
        if (type != ComplicationType.SHORT_TEXT) return null
        val label =
            if (stats.signedIn) pointsLabel(stats.todayPoints) else SIGNED_OUT_TEXT
        return ShortTextComplicationData.Builder(
            text(label),
            text(
                if (stats.signedIn) {
                    "${stats.todayPoints} points claimed today"
                } else {
                    "Sign in to the Postbox Game"
                },
            ),
        )
            .setTitle(text("today"))
            .setTapAction(tapAction())
            .build()
    }
}
