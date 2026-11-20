package com.omnimdm.omni_mdm.sync

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Log
import com.omnimdm.omni_mdm.capture.AppUiCapture
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * Poll HTTP de `/v1/sdk/pending-actions` + ejecución nativa.
 * Idempotencia vía [ExecutedCommandsStore] (anti MQTT+HTTP doble).
 */
internal class SdkActionRunner(
    private val context: Context,
    private val store: SyncStore,
    private val http: AuditHttpTransport,
) {
    @Volatile
    private var activityRef: WeakReference<Activity>? = null
    private val executed = ExecutedCommandsStore.get(context)

    fun attachActivity(activity: Activity?) {
        activityRef = if (activity == null) null else WeakReference(activity)
    }

    fun pollAndRun() {
        try {
            val endpoint = store.endpoint()
            val token = store.token()
            if (endpoint.isBlank() || token.isBlank()) return
            val url = "$endpoint/v1/sdk/pending-actions"
            val (code, body) = http.get(url, authHeaders())
            if (code !in 200..299) return
            val root = JSONObject(body)
            val items = root.optJSONArray("items") ?: JSONArray()
            if (items.length() > 0) {
                store.boostActionPoll(180_000L)
            }
            for (i in 0 until items.length()) {
                val item = items.optJSONObject(i) ?: continue
                handleOne(item)
            }
        } catch (e: Exception) {
            Log.w(TAG, "poll actions fail-open: ${e.message}")
        }
    }

    private fun handleOne(item: JSONObject) {
        val id = item.optString("id")
        val key = item.optString("action_key")
        val params = item.optJSONObject("params") ?: JSONObject()
        if (id.isBlank()) return
        val commandId = params.optString("command_id", id)
        if (executed.alreadyDone(commandId) || executed.alreadyDone(id)) {
            postResult(id, "succeeded", JSONObject().put("idempotent", true).put("transport", "http_poll"))
            return
        }
        when (key.uppercase()) {
            "PING" -> {
                val out = JSONObject()
                    .put("pong", true)
                    .put("control_plane", "sdk")
                    .put("transport", "http_poll")
                    .put("ts", System.currentTimeMillis())
                postResult(id, "succeeded", out)
                executed.mark(commandId, key, "http_poll")
                if (commandId != id) executed.mark(id, key, "http_poll")
            }
            "DEVICE_INFO" -> {
                val ctx = activityRef?.get()?.applicationContext ?: context
                val info = JSONObject()
                    .put("ok", true)
                    .put("control_plane", "sdk")
                    .put("transport", "http_poll")
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("sdk_int", Build.VERSION.SDK_INT)
                    .put("release", Build.VERSION.RELEASE)
                    .put("package_name", ctx.packageName)
                    .put("ts", System.currentTimeMillis())
                postResult(id, "succeeded", info)
                executed.mark(commandId, key, "http_poll")
                if (commandId != id) executed.mark(id, key, "http_poll")
            }
            "RELOAD_CONFIG", "PUBLISH_MANIFEST" -> {
                val out = JSONObject()
                    .put("accepted", true)
                    .put("note", "sdk_http_poll")
                    .put("transport", "http_poll")
                    .put("ts", System.currentTimeMillis())
                postResult(id, "succeeded", out)
                executed.mark(commandId, key, "http_poll")
                if (commandId != id) executed.mark(id, key, "http_poll")
            }
            "CAPTURE_APP_UI" -> {
                if (!store.captureAppUiEnabled()) {
                    postResult(id, "failed", JSONObject().put("error", "capture_disabled_by_server"))
                    return
                }
                val quality = params.optInt("quality", 70)
                val maxEdge = params.optInt("max_edge", 1280)
                val captured = AppUiCapture.capture(activityRef?.get(), quality, maxEdge)
                captured.put("transport", "http_poll")
                val ok = captured.optBoolean("ok", false)
                postResult(id, if (ok) "succeeded" else "failed", captured)
                if (ok) {
                    executed.mark(commandId, key, "http_poll")
                    if (commandId != id) executed.mark(id, key, "http_poll")
                }
            }
            else -> Log.d(TAG, "skip action_key=$key")
        }
    }

    private fun postResult(actionId: String, status: String, result: JSONObject) {
        try {
            val endpoint = store.endpoint()
            val url = "$endpoint/v1/sdk/actions/$actionId/result"
            val body = JSONObject()
                .put("status", status)
                .put("result", result)
                .toString()
            http.post(url, authHeaders() + mapOf("Content-Type" to "application/json"), body)
        } catch (e: Exception) {
            Log.w(TAG, "post action result fail-open: ${e.message}")
        }
    }

    private fun authHeaders(): Map<String, String> {
        val headers = store.extraHeaders().toMutableMap()
        headers["Accept"] = "application/json"
        val token = store.token()
        if (token.isNotEmpty()) headers["Authorization"] = "Bearer $token"
        val key = store.appKey()
        if (key.isNotEmpty()) headers["X-Omni-App-Key"] = key
        return headers
    }

    companion object {
        private const val TAG = "OmniSdkActions"
    }
}
