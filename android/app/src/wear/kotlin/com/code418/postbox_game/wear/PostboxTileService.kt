package com.code418.postbox_game.wear

import android.content.Context
import androidx.concurrent.futures.ResolvableFuture
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DeviceParametersBuilders.DeviceParameters
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.material.CompactChip
import androidx.wear.protolayout.material.Text
import androidx.wear.protolayout.material.Typography
import androidx.wear.protolayout.material.layouts.PrimaryLayout
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.TimeUnit

/**
 * The Postbox tile: today's points and your streak, with a tap straight into a
 * scan.
 *
 * Renders entirely from the SharedPreferences snapshot the app writes (see
 * [WearPrefs]) — no network, no auth, no Flutter engine — so it draws instantly
 * and works with the watch offline.
 *
 * Freshness has three sources, in descending reliability:
 *  1. [FRESHNESS_MILLIS] — the system re-requests the tile on this interval.
 *  2. [onTileEnterEvent] — a re-read whenever the user swipes to the tile.
 *  3. A best-effort push from Dart via `WearDataChangedReceiver`.
 * The push is deliberately NOT load-bearing: it goes through
 * `HomeWidget.updateWidget`, which asks AppWidgetManager for widget ids first,
 * and Wear OS has no launcher widgets. If that path is unavailable the tile is
 * still never staler than (1) or (2).
 */
class PostboxTileService : TileService() {

    override fun onTileRequest(
        requestParams: RequestBuilders.TileRequest,
    ): ListenableFuture<TileBuilders.Tile> {
        val stats = WearPrefs.read(this)
        val tile = TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES_VERSION)
            .setFreshnessIntervalMillis(FRESHNESS_MILLIS)
            .setTileTimeline(
                TimelineBuilders.Timeline.fromLayoutElement(
                    layout(this, requestParams.deviceConfiguration, stats),
                ),
            )
            .build()
        return immediate(tile)
    }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> {
        // v1 is text-only on purpose: a glyph that fails to resolve, or renders
        // differently across watch faces, is a Wear quality rejection waiting
        // to happen, and the numbers carry the meaning anyway.
        return immediate(
            ResourceBuilders.Resources.Builder()
                .setVersion(RESOURCES_VERSION)
                .build(),
        )
    }

    override fun onTileEnterEvent(requestParams: androidx.wear.tiles.EventBuilders.TileEnterEvent) {
        // Swiping to the tile is the moment its numbers matter, so re-read
        // rather than waiting out the freshness interval.
        getUpdater(this).requestUpdate(PostboxTileService::class.java)
    }

    companion object {
        private const val RESOURCES_VERSION = "1"

        /** How often the system re-requests the tile. */
        private val FRESHNESS_MILLIS = TimeUnit.MINUTES.toMillis(30)

        /**
         * Builds the tile layout.
         *
         * [PrimaryLayout] rather than a hand-rolled root Box/Column: it derives
         * its margins from the real [DeviceParameters], which is what keeps
         * content inside a round bezel. Hand-rolling that is precisely how the
         * app's Flutter pages were clipped and rejected in Sept 2026.
         */
        internal fun layout(
            context: Context,
            device: DeviceParameters,
            stats: WearStats,
        ): LayoutElementBuilders.LayoutElement {
            val clickable = ModifiersBuilders.Clickable.Builder()
                .setId("open")
                .setOnClick(
                    ActionBuilders.LaunchAction.Builder()
                        .setAndroidActivity(
                            ActionBuilders.AndroidActivity.Builder()
                                .setPackageName(context.packageName)
                                .setClassName(WearTileLaunchActivity::class.java.name)
                                .build(),
                        )
                        .build(),
                )
                .build()

            val content: LayoutElementBuilders.LayoutElement = if (stats.signedIn) {
                LayoutElementBuilders.Column.Builder()
                    .addContent(
                        Text.Builder(context, pointsLabel(stats.todayPoints))
                            .setTypography(Typography.TYPOGRAPHY_DISPLAY2)
                            .setColor(argb(POSTAL_GOLD))
                            .setMaxLines(1)
                            .build(),
                    )
                    .addContent(
                        Text.Builder(context, "pts today")
                            .setTypography(Typography.TYPOGRAPHY_CAPTION1)
                            .setColor(argb(ON_SURFACE))
                            .setMaxLines(1)
                            .build(),
                    )
                    .addContent(
                        Text.Builder(context, streakLabel(stats.streak))
                            .setTypography(Typography.TYPOGRAPHY_CAPTION2)
                            .setColor(argb(ON_SURFACE_MUTED))
                            .setMaxLines(1)
                            .build(),
                    )
                    .build()
            } else {
                Text.Builder(context, "Sign in to play")
                    .setTypography(Typography.TYPOGRAPHY_BODY2)
                    .setColor(argb(ON_SURFACE))
                    .setMaxLines(2)
                    .build()
            }

            return PrimaryLayout.Builder(device)
                .setResponsiveContentInsetEnabled(true)
                .setPrimaryLabelTextContent(
                    Text.Builder(context, "POSTBOX")
                        .setTypography(Typography.TYPOGRAPHY_CAPTION2)
                        .setColor(argb(POSTAL_RED))
                        .setMaxLines(1)
                        .build(),
                )
                .setContent(content)
                .setPrimaryChipContent(
                    CompactChip.Builder(
                        context,
                        if (stats.signedIn) "Claim" else "Open",
                        clickable,
                        device,
                    )
                        .setChipColors(
                            androidx.wear.protolayout.material.ChipColors(
                                argb(POSTAL_RED),
                                argb(ON_POSTAL_RED),
                            ),
                        )
                        .build(),
                )
                .build()
        }

        // Mirrors lib/theme.dart — postal red #C8102E, gold #FFB400.
        private const val POSTAL_RED = 0xFFC8102E.toInt()
        private const val ON_POSTAL_RED = 0xFFFFFFFF.toInt()
        private const val POSTAL_GOLD = 0xFFFFB400.toInt()
        private const val ON_SURFACE = 0xFFFFFFFF.toInt()
        private const val ON_SURFACE_MUTED = 0xCCFFFFFF.toInt()

        private fun <T> immediate(value: T): ListenableFuture<T> =
            ResolvableFuture.create<T>().apply { set(value) }
    }
}
