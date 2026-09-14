package com.omnimdm.omni_mdm.sync

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

internal interface HostBatchBridge {
    fun take(channelId: String, limit: Int): Pair<JSONArray, List<String>>
    fun ack(channelId: String, ids: List<String>)
}

internal class PushOnlyRunner(
    private val store: SyncStore,
    private val http: AuditHttpTransport,
) {
    fun push(
        channel: JSONObject,
        host: HostBatchBridge?,
        maxBatches: Int = 8,
    ): Int {
        var total = 0
        repeat(maxBatches) {
            val batchMax = store.batchMax()
            val (events, ids) = loadBatch(channel, host, batchMax)
            if (ids.isEmpty()) {
                Log.i(TAG, "push skip channel=${channel.optString("id")} pending=0")
                return total
            }
            val channelId = channel.optString("id", "push")
            postEvents(channel, events, channelId)
            ack(channel, host, ids)
            total += ids.size
            if (ids.size < batchMax) return total
        }
        return total
    }

    private fun loadBatch(
        channel: JSONObject,
        host: HostBatchBridge?,
        limit: Int,
    ): Pair<JSONArray, List<String>> {
        if (channel.optBoolean("useHostProvider", false)) {
            val id = channel.optString("id")
            return host?.take(id, limit) ?: (JSONArray() to emptyList())
        }
        val path = channel.optString("databasePath")
        val table = channel.optString("table")
        if (path.isBlank() || table.isBlank()) return JSONArray() to emptyList()
        return SqliteTableReader.takePending(
            databasePath = path,
            table = table,
            pendingColumn = channel.optString("pendingColumn", "mdm_synced"),
            pendingValue = channel.optString("pendingValue", "0"),
            idColumn = channel.optString("idColumn", "id"),
            limit = limit,
            deviceId = store.deviceId(),
        )
    }

    private fun ack(channel: JSONObject, host: HostBatchBridge?, ids: List<String>) {
        if (channel.optBoolean("useHostProvider", false)) {
            host?.ack(channel.optString("id"), ids)
            return
        }
        SqliteTableReader.markSynced(
            databasePath = channel.optString("databasePath"),
            table = channel.optString("table"),
            pendingColumn = channel.optString("pendingColumn", "mdm_synced"),
            idColumn = channel.optString("idColumn", "id"),
            ids = ids,
        )
    }

    private fun postEvents(channel: JSONObject, events: JSONArray, channelId: String) {
        val deviceId = store.deviceId()
        for (i in 0 until events.length()) {
            val obj = events.optJSONObject(i) ?: continue
            if (obj.optString("device_id").isBlank()) {
                obj.put("device_id", deviceId)
            }
        }
        val count = events.length()
        val body = JSONObject().put("events", events).toString()
        val headers = store.extraHeaders().toMutableMap()
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        val token = store.token()
        if (token.isNotEmpty()) headers["Authorization"] = "Bearer $token"
        val key = store.appKey()
        if (key.isNotEmpty()) headers["X-Omni-App-Key"] = key
        val secret = store.appSecret()
        if (secret.isNotEmpty()) headers["X-Omni-App-Secret"] = secret
        headers["X-Omni-Device-Id"] = store.deviceId()
        val path = channel.optString("pushPath", "/v1/ingest/audit-events")
            .ifBlank { "/v1/ingest/audit-events" }
        val url = store.endpoint() + path
        Log.i(TAG, "audit batch send channel=$channelId count=$count url=$url")
        val (code, payload) = http.post(url, headers, body)
        if (code in 200..299) {
            Log.i(TAG, "audit batch ok channel=$channelId count=$count http=$code body=$payload")
            return
        }
        Log.e(TAG, "audit batch fail channel=$channelId count=$count http=$code body=$payload")
        throw IllegalStateException("ingest_http_$code $payload")
    }

    companion object {
        private const val TAG = "OmniTableSync"
    }
}
