package com.omnimdm.omni_mdm.sync

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Persistencia local de canales y settings PULL_ONLY (overwrite). */
internal class SyncStore(context: Context) {
    private val sp = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun saveAuth(
        endpoint: String,
        appKey: String,
        appSecret: String?,
        token: String?,
        deviceId: String,
        extraHeaders: Map<String, String>,
    ) {
        sp.edit()
            .putString(KEY_ENDPOINT, endpoint.trim().trimEnd('/'))
            .putString(KEY_APP_KEY, appKey)
            .putString(KEY_APP_SECRET, appSecret.orEmpty())
            .putString(KEY_TOKEN, token.orEmpty())
            .putString(KEY_DEVICE_ID, deviceId)
            .putString(KEY_HEADERS, JSONObject(extraHeaders as Map<*, *>).toString())
            .apply()
    }

    fun saveChannels(channelsJson: String) {
        sp.edit().putString(KEY_CHANNELS, channelsJson).apply()
    }

    fun overwriteSettings(intervalSec: Int, batchMax: Int, rawJson: String) {
        val interval = intervalSec.coerceIn(60, 3600)
        val batch = batchMax.coerceIn(10, 500)
        val edit = sp.edit()
            .putInt(KEY_INTERVAL, interval)
            .putInt(KEY_BATCH, batch)
            .putString(KEY_SETTINGS_JSON, rawJson)
        try {
            val o = JSONObject(rawJson)
            edit.putBoolean(KEY_CAPTURE_APP_UI, o.optBoolean("capture_app_ui_enabled", true))
            edit.putInt(KEY_ACTION_POLL, o.optInt("action_poll_sec", 90).coerceIn(10, 300))
            edit.putInt(KEY_ACTION_POLL_ACTIVE, o.optInt("action_poll_active_sec", 20).coerceIn(10, 120))
            edit.putBoolean(KEY_LOCATION_ENABLED, o.optBoolean("location_enabled", true))
            edit.putInt(KEY_LOCATION_TIMEOUT, o.optInt("location_timeout_ms", 15000).coerceIn(3000, 60000))
            edit.putInt(KEY_LOCATION_MAX_AGE, o.optInt("location_max_age_ms", 60000).coerceIn(5000, 600000))
        } catch (_: Exception) {
        }
        edit.apply()
    }

    fun captureAppUiEnabled(): Boolean = sp.getBoolean(KEY_CAPTURE_APP_UI, true)
    fun actionPollSec(): Int = sp.getInt(KEY_ACTION_POLL, 90).coerceIn(10, 300)
    fun actionPollActiveSec(): Int = sp.getInt(KEY_ACTION_POLL_ACTIVE, 20).coerceIn(10, 120)

    fun boostActionPoll(forMs: Long) {
        sp.edit().putLong(KEY_ACTION_BOOST_UNTIL, System.currentTimeMillis() + forMs).apply()
    }

    fun effectiveActionPollSec(): Int {
        val until = sp.getLong(KEY_ACTION_BOOST_UNTIL, 0L)
        return if (until > System.currentTimeMillis()) actionPollActiveSec() else actionPollSec()
    }
    fun locationEnabled(): Boolean = sp.getBoolean(KEY_LOCATION_ENABLED, false)
    fun locationTimeoutMs(): Int = sp.getInt(KEY_LOCATION_TIMEOUT, 15000).coerceIn(3000, 60000)
    fun locationMaxAgeMs(): Int = sp.getInt(KEY_LOCATION_MAX_AGE, 60000).coerceIn(5000, 600000)

    fun endpoint(): String = sp.getString(KEY_ENDPOINT, "").orEmpty()
    fun appKey(): String = sp.getString(KEY_APP_KEY, "").orEmpty()
    fun appSecret(): String = sp.getString(KEY_APP_SECRET, "").orEmpty()
    fun token(): String = sp.getString(KEY_TOKEN, "").orEmpty()
    fun deviceId(): String = sp.getString(KEY_DEVICE_ID, "").orEmpty()
    fun intervalSec(): Int = sp.getInt(KEY_INTERVAL, 300).coerceIn(60, 3600)
    fun batchMax(): Int = sp.getInt(KEY_BATCH, 100).coerceIn(10, 500)

    fun extraHeaders(): Map<String, String> {
        val raw = sp.getString(KEY_HEADERS, "{}") ?: "{}"
        return try {
            val obj = JSONObject(raw)
            buildMap {
                obj.keys().forEach { key -> put(key, obj.optString(key)) }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    fun channels(): List<JSONObject> {
        val raw = sp.getString(KEY_CHANNELS, "[]") ?: "[]"
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun recordFailure() {
        val n = sp.getInt(KEY_FAILS, 0) + 1
        sp.edit()
            .putInt(KEY_FAILS, n)
            .putLong(KEY_OPEN_UNTIL, if (n >= 3) System.currentTimeMillis() + 60_000L else 0L)
            .apply()
    }

    fun recordSuccess() {
        sp.edit().putInt(KEY_FAILS, 0).putLong(KEY_OPEN_UNTIL, 0L).apply()
    }

    fun resetCircuit() {
        sp.edit().putInt(KEY_FAILS, 0).putLong(KEY_OPEN_UNTIL, 0L).apply()
    }

    /** Intervalo inicial desde la app; el PULL de settings puede sobreescribirlo. */
    fun setClientInterval(intervalSec: Int) {
        sp.edit()
            .putInt(KEY_INTERVAL, intervalSec.coerceIn(60, 3600))
            .apply()
    }

    fun circuitOpen(): Boolean {
        val until = sp.getLong(KEY_OPEN_UNTIL, 0L)
        return until > System.currentTimeMillis()
    }

    companion object {
        private const val PREFS = "omni_mdm_table_sync"
        private const val KEY_ENDPOINT = "endpoint"
        private const val KEY_APP_KEY = "app_key"
        private const val KEY_APP_SECRET = "app_secret"
        private const val KEY_TOKEN = "token"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_HEADERS = "headers"
        private const val KEY_CHANNELS = "channels"
        private const val KEY_INTERVAL = "interval_sec"
        private const val KEY_BATCH = "batch_max"
        private const val KEY_SETTINGS_JSON = "settings_json"
        private const val KEY_FAILS = "fail_count"
        private const val KEY_OPEN_UNTIL = "cb_open_until"
        private const val KEY_CAPTURE_APP_UI = "capture_app_ui_enabled"
        private const val KEY_ACTION_POLL = "action_poll_sec"
        private const val KEY_ACTION_POLL_ACTIVE = "action_poll_active_sec"
        private const val KEY_ACTION_BOOST_UNTIL = "action_poll_boost_until"
        private const val KEY_LOCATION_ENABLED = "location_enabled"
        private const val KEY_LOCATION_TIMEOUT = "location_timeout_ms"
        private const val KEY_LOCATION_MAX_AGE = "location_max_age_ms"
    }
}
