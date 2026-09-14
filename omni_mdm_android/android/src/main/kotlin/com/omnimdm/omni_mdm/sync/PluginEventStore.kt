package com.omnimdm.omni_mdm.sync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File

/**
 * Tabla propia del plugin (equivalente a la cola local de Firebase Analytics).
 * Kotlin la posee; el table-sync PUSH_ONLY la sube. No es la DB de la app anfitriona.
 */
internal object PluginEventStore {
    const val TABLE = "omni_events"
    private const val FILE = "omni_mdm_events.db"

    fun path(context: Context): String =
        File(context.applicationContext.filesDir, FILE).absolutePath

    fun ensure(context: Context) {
        val db = SQLiteDatabase.openOrCreateDatabase(path(context), null)
        try {
            try {
                db.enableWriteAheadLogging()
            } catch (_: Exception) {
                // WAL es opcional; CREATE TABLE no debe fallar por el PRAGMA.
            }
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS $TABLE (
                  id TEXT PRIMARY KEY,
                  created_at TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  event_action TEXT NOT NULL,
                  payload TEXT,
                  synced INTEGER NOT NULL DEFAULT 0
                )
                """.trimIndent(),
            )
            db.execSQL(
                "CREATE INDEX IF NOT EXISTS idx_omni_events_synced ON $TABLE(synced)",
            )
        } finally {
            db.close()
        }
    }

    fun enqueue(
        context: Context,
        id: String,
        createdAt: String,
        eventType: String,
        eventAction: String,
        payloadJson: String,
    ) {
        ensure(context)
        val db = SQLiteDatabase.openDatabase(
            path(context),
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        try {
            db.execSQL(
                "INSERT OR REPLACE INTO $TABLE " +
                    "(id, created_at, event_type, event_action, payload, synced) " +
                    "VALUES (?,?,?,?,?,0)",
                arrayOf(id, createdAt, eventType, eventAction, payloadJson),
            )
        } finally {
            db.close()
        }
    }
}
