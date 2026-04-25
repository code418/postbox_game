package com.code418.postbox_game.car

import android.content.Intent
import androidx.car.app.Screen
import androidx.car.app.Session

/** A single-screen Android Auto session that opens on `HomeCarScreen`.
 *  Deep-link intents targeting `postbox://claim?source=carapp` are forwarded
 *  to the home screen so it can trigger an immediate scan. */
class PostboxSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen =
        HomeCarScreen(carContext)
}
