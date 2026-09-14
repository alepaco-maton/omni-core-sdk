package com.omnimdm.omni_mdm

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import com.omnimdm.omni_mdm.sync.HostBatchBridge
import com.omnimdm.omni_mdm.sync.PluginEventStore
import com.omnimdm.omni_mdm.sync.SyncEngine
import com.omnimdm.omni_mdm.sync.SyncScheduler
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class OmniMdmPlugin : FlutterPlugin {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: android.content.Context
    private var scheduler: SyncScheduler? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "omni_mdm")
        scheduler = SyncScheduler(appContext)
        val engine = SyncEngine.get(appContext)
        engine.host = HostBatchBridgeImpl()
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getHardwareFingerprint" -> result.success(androidId())
                "getStableDeviceId" -> result.success(stableDeviceId())
                "getDeviceInfo" -> result.success(collectDeviceInfo())
                "configureTableSync" -> {
                    try {
                        configureSync(call.arguments as? Map<*, *>)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("configure", e.message, null)
                    }
                }
                "scheduleTableSync" -> {
                    scheduler?.schedule()
                    result.success(null)
                }
                "triggerTableSync" -> {
                    scheduler?.triggerNow()
                    result.success(null)
                }
                "runSynchronized" -> {
                    thread {
                        val resetCircuit = call.argument<Boolean>("resetCircuit") ?: false
                        val out = SyncEngine.get(appContext).runSynchronized(resetCircuit)
                        main.post { result.success(out) }
                    }
                }
                "enqueuePluginEvent" -> {
                    thread {
                        try {
                            enqueuePluginEvent(call.arguments as? Map<*, *>)
                        } catch (_: Exception) {
                        }
                        main.post { result.success(null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        SyncEngine.get(appContext).host = null
    }

    @Suppress("UNCHECKED_CAST")
    private fun configureSync(args: Map<*, *>?) {
        if (args == null) return
        val endpoint = args["endpoint"]?.toString().orEmpty()
        val appKey = args["appKey"]?.toString().orEmpty()
        val appSecret = args["appSecret"]?.toString()
        val token = args["token"]?.toString()
        val deviceId = args["deviceId"]?.toString() ?: stableDeviceId()
        val headers = (args["headers"] as? Map<*, *>)?.mapNotNull { (k, v) ->
            if (k == null || v == null) null else k.toString() to v.toString()
        }?.toMap() ?: emptyMap()
        val channels = args["channels"]
        val channelsJson = when (channels) {
            is List<*> -> JSONArray(channels).toString()
            is String -> channels
            else -> "[]"
        }
        val engine = SyncEngine.get(appContext)
        engine.store().saveAuth(endpoint, appKey, appSecret, token, deviceId, headers)
        val intervalSec = (args["syncIntervalSec"] as? Number)?.toInt()
        if (intervalSec != null && intervalSec > 0) {
            engine.store().setClientInterval(intervalSec)
        }
        if (channelsJson != "[]") {
            engine.store().saveChannels(channelsJson)
        }
        engine.host = HostBatchBridgeImpl()
    }

    private fun enqueuePluginEvent(args: Map<*, *>?) {
        if (args == null) return
        val id = args["id"]?.toString().orEmpty()
        if (id.isBlank()) return
        PluginEventStore.enqueue(
            context = appContext,
            id = id,
            createdAt = args["created_at"]?.toString() ?: java.time.Instant.now().toString(),
            eventType = args["event_type"]?.toString() ?: "custom",
            eventAction = args["event_action"]?.toString() ?: "log",
            payloadJson = args["payload"]?.toString() ?: "{}",
        )
    }

    private inner class HostBatchBridgeImpl : HostBatchBridge {
        override fun take(channelId: String, limit: Int): Pair<JSONArray, List<String>> {
            val latch = CountDownLatch(1)
            var events = JSONArray()
            var ids = emptyList<String>()
            main.post {
                channel.invokeMethod(
                    "takePushBatch",
                    mapOf("channelId" to channelId, "limit" to limit),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            try {
                                val map = result as? Map<*, *>
                                val rawEvents = map?.get("events")
                                val rawIds = map?.get("ids")
                                events = when (rawEvents) {
                                    is List<*> -> JSONArray(rawEvents)
                                    is String -> JSONArray(rawEvents)
                                    else -> JSONArray()
                                }
                                ids = (rawIds as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                            } catch (_: Exception) {
                            }
                            latch.countDown()
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            latch.countDown()
                        }
                    },
                )
            }
            latch.await(20, TimeUnit.SECONDS)
            return events to ids
        }

        override fun ack(channelId: String, ids: List<String>) {
            val latch = CountDownLatch(1)
            main.post {
                channel.invokeMethod(
                    "ackPushBatch",
                    mapOf("channelId" to channelId, "ids" to ids),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            latch.countDown()
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            latch.countDown()
                        }
                    },
                )
            }
            latch.await(15, TimeUnit.SECONDS)
        }
    }

    private fun androidId(): String? =
        Settings.Secure.getString(appContext.contentResolver, Settings.Secure.ANDROID_ID)

    /** ID estable del dispositivo, independiente del usuario de la app. */
    private fun stableDeviceId(): String {
        val sp = appContext.getSharedPreferences("omni_mdm_identity", Context.MODE_PRIVATE)
        var uuid = sp.getString("device_uuid", null)
        if (uuid.isNullOrBlank()) {
            uuid = java.util.UUID.randomUUID().toString()
            sp.edit().putString("device_uuid", uuid).apply()
        }
        val android = androidId()?.trim().orEmpty().ifBlank { "unknown" }
        return if (android == "unknown") "sdk-dev-$uuid" else "sdk-$android"
    }

    /**
     * Inventario técnico. Mantiene claves planas (compat) y añade bloques anidados.
     * No incluye IMEI, IMSI, MAC ni serial (RN-ENR-01).
     */
    private fun collectDeviceInfo(): Map<String, Any?> {
        val pm = appContext.packageManager
        val pkg = appContext.packageName
        val pkgInfo = try {
            if (Build.VERSION.SDK_INT >= 33) {
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
            }
        } catch (_: Exception) {
            null
        }
        val versionName = pkgInfo?.versionName
        val versionCode = if (pkgInfo != null) {
            if (Build.VERSION.SDK_INT >= 28) pkgInfo.longVersionCode else {
                @Suppress("DEPRECATION")
                pkgInfo.versionCode.toLong()
            }
        } else null

        val battery = batterySnapshot()
        val storage = storageSnapshot()
        val dm = appContext.resources.displayMetrics
        val cfg = appContext.resources.configuration
        val localeTag = cfg.locales[0]?.toLanguageTag()

        val out = linkedMapOf<String, Any?>(
            "schema" to "omni.device_inventory.v1",
            "control_plane" to "sdk",
            "hardware_fingerprint" to stableDeviceId(),
            "device_uuid" to appContext.getSharedPreferences("omni_mdm_identity", Context.MODE_PRIVATE)
                .getString("device_uuid", ""),
            "platform" to "android",
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "product" to Build.PRODUCT,
            "os_version" to Build.VERSION.RELEASE,
            "sdk_int" to Build.VERSION.SDK_INT,
            "package_name" to pkg,
            "app_version" to versionName,
            "app_build" to versionCode,
            "battery_level" to battery["percent"],
            "battery_charging" to battery["charging"],
            "storage_total_bytes" to storage["data_total_bytes"],
            "storage_free_bytes" to storage["data_available_bytes"],
            "locale" to localeTag,
            "observed_at" to java.time.Instant.now().toString(),
            "build" to mapOf(
                "manufacturer" to Build.MANUFACTURER,
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "device" to Build.DEVICE,
                "product" to Build.PRODUCT,
                "hardware" to Build.HARDWARE,
                "display" to Build.DISPLAY,
                "fingerprint" to Build.FINGERPRINT,
                "supported_abis" to Build.SUPPORTED_ABIS.toList(),
            ),
            "os" to mapOf(
                "platform" to "android",
                "release" to Build.VERSION.RELEASE,
                "sdk_int" to Build.VERSION.SDK_INT,
                "security_patch" to Build.VERSION.SECURITY_PATCH,
                "incremental" to Build.VERSION.INCREMENTAL,
                "uptime_ms" to SystemClock.elapsedRealtime(),
            ),
            "screen" to mapOf(
                "width_px" to dm.widthPixels,
                "height_px" to dm.heightPixels,
                "density_dpi" to dm.densityDpi,
                "smallest_width_dp" to cfg.smallestScreenWidthDp,
            ),
            "locale_detail" to mapOf(
                "language_tag" to (localeTag ?: Locale.getDefault().toLanguageTag()),
                "timezone" to TimeZone.getDefault().id,
            ),
            "memory" to memorySnapshot(),
            "storage" to storage,
            "battery" to battery,
            "network" to networkSnapshot(),
        )
        return out
    }

    private fun batterySnapshot(): Map<String, Any?> {
        return try {
            val intent = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val health = intent?.getIntExtra(BatteryManager.EXTRA_HEALTH, -1) ?: -1
            val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val temp = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0
            val volt = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0
            val pct = if (level >= 0 && scale > 0) (level * 100) / scale else null
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            mapOf(
                "percent" to pct,
                "charging" to charging,
                "status" to status,
                "health" to health,
                "plugged" to plugged,
                "temperature_tenths_c" to temp,
                "voltage_mv" to volt,
                "technology" to (intent?.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY) ?: ""),
            )
        } catch (_: Exception) {
            mapOf("percent" to null, "charging" to null)
        }
    }

    private fun storageSnapshot(): Map<String, Any?> {
        return try {
            val path = Environment.getDataDirectory()
            val stat = StatFs(path.path)
            mapOf(
                "data_total_bytes" to stat.totalBytes,
                "data_available_bytes" to stat.availableBytes,
            )
        } catch (_: Exception) {
            mapOf("data_total_bytes" to null, "data_available_bytes" to null)
        }
    }

    private fun memorySnapshot(): Map<String, Any?> {
        return try {
            val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            mapOf(
                "total_bytes" to mi.totalMem,
                "available_bytes" to mi.availMem,
                "low_memory" to mi.lowMemory,
                "class_mb" to am.memoryClass,
            )
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun networkSnapshot(): Map<String, Any?> {
        return try {
            val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = cm.activeNetwork
            val caps = if (net != null) cm.getNetworkCapabilities(net) else null
            mapOf(
                "has_internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
                "validated" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
                "wifi" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
                "cellular" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true),
                "vpn" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true),
            )
        } catch (_: Exception) {
            emptyMap()
        }
    }
}
