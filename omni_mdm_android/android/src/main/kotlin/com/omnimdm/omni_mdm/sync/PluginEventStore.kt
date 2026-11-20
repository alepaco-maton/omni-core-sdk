package com.omnimdm.omni_mdm.sync

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File

/**
 * Tabla propia del plugin (equivalente a la cola local de Firebase Analytics).
 * Kotlin la posee; el table-sync PUSH_ONLY la sube. No es la DB de la app anfitriona.
 *
 * Una conexión compartida y escrituras serializadas: cada evento llega en su propio
 * hilo y SQLite rechaza escrituras paralelas desde conexiones distintas.
 */
internal object PluginEventStore {
    const val TABLE = "omni_events"
    private const val FILE = "omni_mdm_events.db"

    @Volatile private var db: SQLiteDatabase? = null

    fun path(context: Context): String =
        File(context.applicationContext.filesDir, FILE).absolutePath

    fun ensure(context: Context) {
        open(context)
    }

    @Synchronized
    private fun open(context: Context): SQLiteDatabase {
        db?.let { if (it.isOpen) return it }
        val opened = SQLiteDatabase.openOrCreateDatabase(path(context), null)
        try {
            opened.enableWriteAheadLogging()
        } catch (_: Exception) {
            // WAL es opcional; CREATE TABLE no debe fallar por el PRAGMA.
        }
        opened.execSQL(
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
        opened.execSQL("CREATE INDEX IF NOT EXISTS idx_omni_events_synced ON $TABLE(synced)")
        db = opened
        return opened
    }

    @Synchronized
    fun enqueue(
        context: Context,
        id: String,
        createdAt: String,
        eventType: String,
        eventAction: String,
        payloadJson: String,
    ) {
        open(context).execSQL(
            "INSERT OR REPLACE INTO $TABLE " +
                "(id, created_at, event_type, event_action, payload, synced) " +
                "VALUES (?,?,?,?,?,0)",
            arrayOf(id, createdAt, eventType, eventAction, payloadJson),
        )
    }

    /** Ya subidos: conserva los últimos [keep] para diagnóstico; el resto se borra. */
    @Synchronized
    fun purgeSynced(context: Context, keep: Int = 500) {
        if (!File(path(context)).exists()) return
        open(context).execSQL(
            "DELETE FROM $TABLE WHERE synced = 1 AND id NOT IN (" +
                "SELECT id FROM $TABLE WHERE synced = 1 ORDER BY created_at DESC LIMIT ?)",
            arrayOf<Any>(keep),
        )
    }
}
