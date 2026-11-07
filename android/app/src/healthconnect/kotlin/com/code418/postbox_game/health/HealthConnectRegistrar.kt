package com.code418.postbox_game.health

import io.flutter.embedding.engine.FlutterEngine

/**
 * Registers the Health Connect bridge on the UI engine. Phone-side flavours
 * get this real version; the wear flavour compiles a no-op of the same name
 * (src/wear/kotlin/.../health/HealthConnectRegistrar.kt) so MainActivity builds
 * everywhere. Only MainActivity's engine registers it — background engines
 * (home_widget) never can, which also enforces "no background reads".
 */
object HealthConnectRegistrar {
    fun register(engine: FlutterEngine) {
        engine.plugins.add(HealthConnectPlugin())
    }
}
