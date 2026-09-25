package com.code418.postbox_game.car

import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/** Android Auto entry point. Registered in AndroidManifest.xml with the
 *  `androidx.car.app.CarAppService` action. */
class PostboxCarAppService : CarAppService() {
    /**
     * Only the real Android Auto / Automotive hosts (the library's signed
     * allowlist) may bind. The service is exported, so accepting any host, as
     * ALLOW_ALL_HOSTS_VALIDATOR does, would let any app on the phone pose as
     * a car head unit: read the rendered stats and leaderboard, and trigger
     * "Claim nearby postbox" with the user's session and location. Android's
     * docs restrict that validator to debug builds, which is the only place
     * it is still used (for the desktop head unit and emulators).
     */
    override fun createHostValidator(): HostValidator =
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        } else {
            HostValidator.Builder(applicationContext)
                .addAllowedHosts(androidx.car.app.R.array.hosts_allowlist_sample)
                .build()
        }

    override fun onCreateSession(): Session = PostboxSession()
}
