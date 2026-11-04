package com.code418.postbox_game.car

import android.content.Intent
import androidx.car.app.Screen
import androidx.car.app.Session

/** A single-screen Android Auto session that opens on `HomeCarScreen`.
 *  The launch intent is not inspected: the car surface has no deep link of
 *  its own (claims start from the screen's quick-claim action). */
class PostboxSession : Session() {
    override fun onCreateScreen(intent: Intent): Screen =
        HomeCarScreen(carContext)
}
