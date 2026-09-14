package com.omnimdm.omni_mdm.sync

import org.json.JSONObject

internal class PullOnlyRunner(
    private val store: SyncStore,
    private val http: AuditHttpTransport,
) {
    fun pull(channel: JSONObject) {
        val path = channel.optString("pullPath", "/v1/sdk/settings").ifBlank { "/v1/sdk/settings" }
        val url = store.endpoint() + path
        val headers = authHeaders()
        val (code, body) = http.get(url, headers)
        if (code !in 200..299) {
            throw IllegalStateException("settings_http_$code")
        }
        val json = JSONObject(body)
        val interval = json.optInt("sync_interval_sec", 300)
        val batch = json.optInt("batch_max", 100)
        store.overwriteSettings(interval, batch, body)
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
}
