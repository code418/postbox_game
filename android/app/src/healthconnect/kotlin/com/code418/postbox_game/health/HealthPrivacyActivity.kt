package com.code418.postbox_game.health

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * Health Connect's "privacy policy" link for this app. Health Connect starts
 * it via androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE (Android 13 and
 * lower) or the ViewPermissionUsageActivity alias (Android 14+); both are
 * declared in the phone/auto manifests. An invisible trampoline (like
 * WearTileLaunchActivity): it opens the hosted privacy policy — the same one
 * the Play listing links, as Health Connect requires — and finishes.
 */
class HealthPrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_URL)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, PRIVACY_URL, Toast.LENGTH_LONG).show()
        }
        finish()
    }

    companion object {
        /** Must start with kHostedPrivacyPolicyUrl (lib/legal/privacy_policy_screen.dart);
         *  pinned by test/health_connect_manifest_test.dart. */
        const val PRIVACY_URL = "https://the-postbox-game.web.app/privacy-policy#health-connect"
    }
}
