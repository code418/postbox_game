package com.code418.postbox_game.car

import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/** Android Auto entry point. Registered in AndroidManifest.xml with the
 *  `androidx.car.app.CarAppService` action. */
class PostboxCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(): Session = PostboxSession()
}
