package com.omnimdm.omni_mdm.sync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Idempotencia local plugin (MQTT + HTTP poll). Purge > 30 días. */
internal class ExecutedCommandsStore(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB, null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS executed_commands (
              command_id TEXT PRIMARY KEY NOT NULL,
              command_key TEXT NOT NULL DEFAULT '',
              transport TEXT NOT NULL DEFAULT '',
              executed_at_ms INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS executed_commands_at_idx ON executed_commands (executed_at_ms)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    fun alreadyDone(commandId: String): Boolean {
        if (commandId.isBlank()) return false
        purgeOld()
        readableDatabase.rawQuery(
            "SELECT 1 FROM executed_commands WHERE command_id = ? LIMIT 1",
            arrayOf(commandId),
        ).use { c -> return c.moveToFirst() }
    }

    fun mark(commandId: String, commandKey: String, transport: String) {
        if (commandId.isBlank()) return
        purgeOld()
        writableDatabase.execSQL(
            """
            INSERT OR REPLACE INTO executed_commands (command_id, command_key, transport, executed_at_ms)
            VALUES (?, ?, ?, ?)
            """.trimIndent(),
            arrayOf(commandId, commandKey, transport, System.currentTimeMillis()),
        )
    }

    fun purgeOld() {
        val cutoff = System.currentTimeMillis() - RETENTION_MS
        try {
            writableDatabase.execSQL(
                "DELETE FROM executed_commands WHERE executed_at_ms < ?",
                arrayOf(cutoff),
            )
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val DB = "omni_plugin_executed_commands.db"
        private const val RETENTION_MS = 30L * 24 * 60 * 60 * 1000
        @Volatile private var instance: ExecutedCommandsStore? = null
        fun get(context: Context): ExecutedCommandsStore {
            return instance ?: synchronized(this) {
                instance ?: ExecutedCommandsStore(context).also { instance = it }
            }
        }
    }
}
