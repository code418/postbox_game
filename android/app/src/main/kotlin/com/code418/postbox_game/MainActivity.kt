package com.code418.postbox_game

import com.code418.postbox_game.health.HealthConnectRegistrar
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

// Deliberately still a plain FlutterActivity (not FlutterFragmentActivity):
// the Health Connect bridge launches its permission / route-consent contracts
// with startActivityForResult and reads the result through the plugin
// ActivityResultListener, which FlutterActivity forwards.
class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // GeneratedPluginRegistrant
        HealthConnectRegistrar.register(flutterEngine)
    }
}
