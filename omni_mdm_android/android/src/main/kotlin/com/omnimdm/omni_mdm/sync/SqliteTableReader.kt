package com.omnimdm.omni_mdm.sync

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

internal object SqliteTableReader {
    private const val TAG = "OmniTableSync"
    private val IDENT = Regex("^[A-Za-z0-9_]+$")

    fun ident(name: String): String {
        require(name.matches(IDENT)) { "invalid_ident" }
        return name
    }

    fun takePending(
        databasePath: String,
        table: String,
        pendingColumn: String,
        pendingValue: String,
        idColumn: String,
        limit: Int,
        deviceId: String,
    ): Pair<JSONArray, List<String>> {
        val t = ident(table)
        val col = ident(pendingColumn)
        val id = ident(idColumn)
        val db = SQLiteDatabase.openDatabase(
            databasePath,
            null,
            SQLiteDatabase.OPEN_READONLY,
        )
        try {
            val where = if (pendingValue == "0" && col == "mdm_synced") {
                "($col = 0 OR $col IS NULL)"
            } else {
                "$col = ?"
            }
            val args = if (where.contains("?")) {
                arrayOf(pendingValue, limit.toString())
            } else {
                arrayOf(limit.toString())
            }
            val cursor = db.rawQuery(
                "SELECT * FROM $t WHERE $where ORDER BY $id ASC LIMIT ?",
                args,
            )
            val events = JSONArray()
            val ids = mutableListOf<String>()
            cursor.use {
                while (it.moveToNext()) {
                    val rowId = it.string(id) ?: continue
                    ids.add(rowId)
                    events.put(mapRow(it, deviceId, rowId, t))
                }
            }
            if (ids.isEmpty()) {
                Log.i(
                    TAG,
                    "audit pending=0 table=$t db=$databasePath col=$col val=$pendingValue",
                )
            } else {
                Log.i(TAG, "audit pending=${ids.size} table=$t db=$databasePath")
            }
            return events to ids
        } finally {
            db.close()
        }
    }

    fun markSynced(
        databasePath: String,
        table: String,
        pendingColumn: String,
        idColumn: String,
        ids: List<String>,
    ) {
        if (ids.isEmpty()) return
        val t = ident(table)
        val col = ident(pendingColumn)
        val id = ident(idColumn)
        val placeholders = ids.joinToString(",") { "?" }
        val db = SQLiteDatabase.openDatabase(
            databasePath,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        try {
            db.execSQL(
                "UPDATE $t SET $col = 1 WHERE $id IN ($placeholders)",
                ids.toTypedArray(),
            )
        } finally {
            db.close()
        }
    }

    private fun mapRow(c: Cursor, deviceId: String, rowId: String, table: String): JSONObject {
        if (table == "audit_logs") return mapBoaAudit(c, deviceId, rowId)
        if (table == PluginEventStore.TABLE) return mapPluginEvent(c, deviceId, rowId)
        return JSONObject().apply {
            put("client_event_id", rowId)
            put("device_id", deviceId)
            put("observed_at", c.string("timestamp") ?: c.string("created_at") ?: "")
            put("event_type", c.string("event_type") ?: "custom")
            put("event_action", c.string("event_action") ?: c.string("category") ?: "log")
        }
    }

    private fun mapPluginEvent(c: Cursor, deviceId: String, rowId: String): JSONObject {
        val payload = try {
            JSONObject(c.string("payload") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val metadata = payload.optJSONObject("metadata") ?: JSONObject()
        return JSONObject().apply {
            put("client_event_id", rowId)
            put("device_id", deviceId)
            put("observed_at", c.string("created_at") ?: "")
            put("event_type", c.string("event_type") ?: "custom")
            put("event_action", c.string("event_action") ?: "log")
            putOpt("screen_name", payload.optString("screen_name").ifBlank { null })
            putOpt("endpoint", payload.optString("endpoint").ifBlank { null })
            putOpt("user_name", payload.optString("user_name").ifBlank { null })
            putOpt("ip_address", payload.optString("ip_address").ifBlank { null })
            putOpt("json_request", payload.optString("json_request").ifBlank { null })
            putOpt("json_response", payload.optString("json_response").ifBlank { null })
            if (metadata.length() > 0) put("metadata", metadata)
        }
    }

    private fun mapBoaAudit(c: Cursor, deviceId: String, rowId: String): JSONObject {
        val action = try {
            JSONObject(c.string("action") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val metadata = action.opt("metadata")
        return JSONObject().apply {
            put("client_event_id", rowId)
            put("device_id", deviceId)
            put("observed_at", c.string("timestamp") ?: "")
            put("event_type", action.optString("event_type", "system"))
            put("event_action", action.optString("event_action", "unknown"))
            putOpt("screen_name", action.optString("screen_name").ifBlank { null })
            putOpt("endpoint", c.string("endpoint"))
            putOpt("user_name", c.string("user_name"))
            putOpt("ip_address", c.string("ip_address"))
            if (metadata is JSONObject) put("metadata", metadata)
            putOpt("json_request", c.string("json_request"))
            putOpt("json_response", c.string("json_response"))
        }
    }

    private fun Cursor.string(column: String): String? {
        val i = getColumnIndex(column)
        if (i < 0 || isNull(i)) return null
        return getString(i)
    }
}
