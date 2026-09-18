package com.code418.postbox_game.wear

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import com.code418.postbox_game.MainActivity
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * Invisible trampoline from the tile into the app.
 *
 * A protolayout [androidx.wear.protolayout.ModifiersBuilders.Clickable] can
 * only carry a `LaunchAction`, whose `AndroidActivity` names a component and
 * extras — it cannot carry a data URI. The complications, which take a real
 * PendingIntent, don't need this; the tile does. Twenty lines of trampoline
 * keeps one deep-link contract across widget, tile and complication instead of
 * inventing a second, extras-based one.
 *
 * It deliberately IGNORES every incoming extra and hard-codes its target, so an
 * exported activity can never be talked into launching something else on the
 * caller's behalf (intent redirection).
 */
class WearTileLaunchActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                // The action home_widget listens for, so the tap arrives on the
                // same cold-start check and widgetClicked stream the phone
                // widget uses rather than a second Dart-side channel.
                action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
                data = Uri.parse(DEEP_LINK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
        )
        finish()
    }

    companion object {
        /**
         * Parsed by `isClaimDeepLink` in `lib/deep_links.dart`; the `source`
         * distinguishes this entry point from the widget and complications in
         * analytics. Pinned against the Dart parser in `test/widget_test.dart`.
         */
        const val DEEP_LINK = "postbox://claim?source=tile"
    }
}
