package com.code418.postbox_game.health

import io.flutter.embedding.engine.FlutterEngine

/**
 * Wear OS: no Health Connect. This no-op exists so MainActivity (src/main)
 * compiles for the wear flavour; the real bridge lives in src/healthconnect,
 * which only the phone-side flavours compile. On the watch the Dart side sees
 * MissingPluginException and treats workout claims as unsupported.
 */
object HealthConnectRegistrar {
    @Suppress("UNUSED_PARAMETER")
    fun register(engine: FlutterEngine) {
        // Intentionally empty.
    }
}
