package com.code418.postbox_game.health

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.contracts.ExerciseRouteRequestContract
import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseRouteResult
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * Read-only Health Connect bridge for workout claims (channel
 * [HealthConnectMapping.CHANNEL]). The Dart side
 * (lib/services/health_connect_bridge.dart) owns all policy — which sessions
 * are eligible, when to read, what to send — so this stays a thin adapter:
 *
 *   getStatus, getGrantedPermissions, requestPermissions,
 *   readSessions{sinceMs,untilMs}, readRoute{id}, requestRouteConsent{id},
 *   openHealthConnectSettings, openHealthConnectInstall, revokeAllPermissions
 *
 * Contracts (permission request, per-session route consent) are launched with
 * startActivityForResult on the plain FlutterActivity and parsed in
 * [onActivityResult], so MainActivity needn't be a FragmentActivity.
 *
 * Nothing is written to Health Connect, and titles / heart rate / any other
 * data are never read. Reads of other apps' routes only succeed while the app
 * is in the foreground (Health Connect enforces this).
 */
class HealthConnectPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activityBinding: ActivityPluginBinding? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val permissionContract =
        PermissionController.createRequestPermissionResultContract(HealthConnectMapping.PROVIDER_PACKAGE)
    private val routeContract = ExerciseRouteRequestContract()
    private var pendingPermissions: MethodChannel.Result? = null
    private var pendingRoute: MethodChannel.Result? = null

    // ── FlutterPlugin / ActivityAware ──────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, HealthConnectMapping.CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    // A config change keeps any in-flight request: the result arrives on the
    // re-attached activity's listener. Only a real detach fails it.
    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        pendingPermissions?.error("no_activity", "The app went away mid-request", null)
        pendingPermissions = null
        pendingRoute?.error("no_activity", "The app went away mid-request", null)
        pendingRoute = null
    }

    // ── Method calls ───────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(statusMap())
            "getGrantedPermissions" -> withClient(result) { client ->
                result.success(granted(client).toList())
            }
            "requestPermissions" -> requestPermissions(result)
            "readSessions" -> {
                val since = call.argument<Number>("sinceMs")?.toLong()
                val until = call.argument<Number>("untilMs")?.toLong()
                if (since == null || until == null || until < since) {
                    result.error("invalid_argument", "sinceMs/untilMs required", null)
                    return
                }
                withClient(result) { client -> result.success(readSessions(client, since, until)) }
            }
            "readRoute" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrEmpty()) {
                    result.error("invalid_argument", "id required", null)
                    return
                }
                withClient(result) { client -> result.success(readRoute(client, id)) }
            }
            "requestRouteConsent" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrEmpty()) {
                    result.error("invalid_argument", "id required", null)
                    return
                }
                requestRouteConsent(id, result)
            }
            "openHealthConnectSettings" -> result.success(openSettings())
            "openHealthConnectInstall" -> result.success(openInstall())
            "revokeAllPermissions" -> withClient(result) { client ->
                client.permissionController.revokeAllPermissions()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun sdkStatus(): Int =
        if (Build.VERSION.SDK_INT >= 28) {
            HealthConnectClient.getSdkStatus(appContext, HealthConnectMapping.PROVIDER_PACKAGE)
        } else {
            HealthConnectClient.SDK_UNAVAILABLE
        }

    private fun statusMap(): Map<String, Any> = mapOf(
        "status" to HealthConnectMapping.statusName(
            Build.VERSION.SDK_INT,
            sdkStatus(),
            HealthConnectClient.SDK_AVAILABLE,
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED,
        ),
        "sdkInt" to Build.VERSION.SDK_INT,
    )

    /** Run [block] with a client, mapping failures to channel error codes. */
    private fun withClient(result: MethodChannel.Result, block: suspend (HealthConnectClient) -> Unit) {
        if (sdkStatus() != HealthConnectClient.SDK_AVAILABLE) {
            result.error("unavailable", "Health Connect is not available", null)
            return
        }
        scope.launch {
            try {
                block(HealthConnectClient.getOrCreate(appContext))
            } catch (e: SecurityException) {
                result.error("permission_denied", e.message, null)
            } catch (e: IllegalArgumentException) {
                result.error("invalid_argument", e.message, null)
            } catch (e: IllegalStateException) {
                result.error("not_foreground", e.message, null)
            } catch (e: Exception) {
                result.error("unavailable", e.message, null)
            }
        }
    }

    private suspend fun granted(client: HealthConnectClient): Set<String> =
        client.permissionController.getGrantedPermissions().intersect(HealthConnectMapping.PERMISSIONS)

    private suspend fun readSessions(client: HealthConnectClient, sinceMs: Long, untilMs: Long): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        var pageToken: String? = null
        var pages = 0
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    ExerciseSessionRecord::class,
                    TimeRangeFilter.between(Instant.ofEpochMilli(sinceMs), Instant.ofEpochMilli(untilMs)),
                    pageToken = pageToken,
                ),
            )
            for (r in response.records) {
                val type = HealthConnectMapping.exerciseTypeName(r.exerciseType) ?: continue
                out.add(
                    mapOf(
                        "id" to r.metadata.id,
                        "type" to type,
                        "startMs" to r.startTime.toEpochMilli(),
                        "endMs" to r.endTime.toEpochMilli(),
                        "lastModifiedMs" to r.metadata.lastModifiedTime.toEpochMilli(),
                        "originPackage" to r.metadata.dataOrigin.packageName,
                        "recordingMethod" to HealthConnectMapping.recordingMethodName(r.metadata.recordingMethod),
                    ),
                )
            }
            pageToken = response.pageToken
            pages++
        } while (pageToken != null && pages < MAX_PAGES && out.size < MAX_SESSIONS)
        return out
    }

    private suspend fun readRoute(client: HealthConnectClient, id: String): Map<String, Any> {
        val record = client.readRecord(ExerciseSessionRecord::class, id).record
        return when (val r = record.exerciseRouteResult) {
            is ExerciseRouteResult.Data -> encode(r.exerciseRoute)
            is ExerciseRouteResult.ConsentRequired -> mapOf("status" to "consent_required")
            else -> mapOf("status" to "no_data")
        }
    }

    private fun encode(route: ExerciseRoute): Map<String, Any> =
        HealthConnectMapping.encodeRoute(
            route.route.map {
                HealthConnectMapping.RouteFix(
                    tMs = it.time.toEpochMilli(),
                    lat = it.latitude,
                    lng = it.longitude,
                    accuracyM = it.horizontalAccuracy?.inMeters,
                )
            },
        ).toMap()

    // ── Contracts ──────────────────────────────────────────────────────────

    private fun requestPermissions(result: MethodChannel.Result) {
        val activity: Activity = activityBinding?.activity ?: run {
            result.error("no_activity", "No foreground activity", null)
            return
        }
        if (pendingPermissions != null) {
            result.error("busy", "A permission request is already showing", null)
            return
        }
        try {
            val intent = permissionContract.createIntent(activity, HealthConnectMapping.PERMISSIONS)
            pendingPermissions = result
            activity.startActivityForResult(intent, REQ_PERMISSIONS)
        } catch (e: ActivityNotFoundException) {
            pendingPermissions = null
            result.error("unavailable", "Health Connect could not be opened", null)
        }
    }

    private fun requestRouteConsent(id: String, result: MethodChannel.Result) {
        val activity: Activity = activityBinding?.activity ?: run {
            result.error("no_activity", "No foreground activity", null)
            return
        }
        if (pendingRoute != null) {
            result.error("busy", "A route request is already showing", null)
            return
        }
        try {
            val intent = routeContract.createIntent(activity, id)
            pendingRoute = result
            activity.startActivityForResult(intent, REQ_ROUTE)
        } catch (e: Exception) {
            pendingRoute = null
            result.success(mapOf("status" to "unsupported"))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQ_PERMISSIONS -> {
                val result = pendingPermissions ?: return true
                pendingPermissions = null
                val granted = try {
                    permissionContract.parseResult(resultCode, data).intersect(HealthConnectMapping.PERMISSIONS)
                } catch (e: Exception) {
                    emptySet()
                }
                result.success(granted.toList())
                return true
            }
            REQ_ROUTE -> {
                val result = pendingRoute ?: return true
                pendingRoute = null
                val route = try {
                    routeContract.parseResult(resultCode, data)
                } catch (e: Exception) {
                    null
                }
                result.success(if (route != null) encode(route) else mapOf("status" to "denied"))
                return true
            }
        }
        return false
    }

    // ── Settings / install ─────────────────────────────────────────────────

    private fun startFirst(intents: List<Intent>): Boolean {
        val ctx: Context = activityBinding?.activity ?: appContext
        for (intent in intents) {
            if (ctx !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                ctx.startActivity(intent)
                return true
            } catch (e: ActivityNotFoundException) {
                // try the next one
            } catch (e: SecurityException) {
                // try the next one
            }
        }
        return false
    }

    private fun openSettings(): Boolean = startFirst(
        if (Build.VERSION.SDK_INT >= 34) {
            listOf(
                // This app's own Health Connect permissions page (Android 14+).
                Intent("android.health.connect.action.MANAGE_HEALTH_PERMISSIONS")
                    .putExtra(Intent.EXTRA_PACKAGE_NAME, appContext.packageName),
                Intent("android.health.connect.action.HEALTH_HOME_SETTINGS"),
            )
        } else {
            listOf(Intent("androidx.health.ACTION_HEALTH_CONNECT_SETTINGS"))
        },
    )

    private fun openInstall(): Boolean {
        val pkg = HealthConnectMapping.PROVIDER_PACKAGE
        return startFirst(
            listOf(
                Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg&url=healthconnect%3A%2F%2Fonboarding"))
                    .setPackage("com.android.vending")
                    .putExtra("overlay", true)
                    .putExtra("callerId", appContext.packageName),
                Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg")),
            ),
        )
    }

    private companion object {
        const val REQ_PERMISSIONS = 0x4843 // "HC"
        const val REQ_ROUTE = 0x4844
        const val MAX_PAGES = 10
        const val MAX_SESSIONS = 200
    }
}
