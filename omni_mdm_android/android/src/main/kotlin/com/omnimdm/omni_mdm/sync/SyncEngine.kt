package com.omnimdm.omni_mdm.sync

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.json.JSONObject

/**
 * Orden del ciclo: PULL_ONLY (settings overwrite) → PUSH_ONLY (audit, sin conflictos).
 * Fail-open: un fallo no lanza a la app anfitriona.
 */
internal class SyncEngine(
    context: Context,
    var host: HostBatchBridge? = null,
) {
    private val appContext = context.applicationContext
    private val store = SyncStore(appContext)
    private val http = AuditHttpTransport()
    private val pull = PullOnlyRunner(store, http)
    private val push = PushOnlyRunner(store, http)
    private val actions = SdkActionRunner(appContext, store, http)
    private val lock = Any()

    fun store(): SyncStore = store
    fun actions(): SdkActionRunner = actions

    fun runSynchronized(resetCircuit: Boolean = false): Map<String, Any> {
        synchronized(lock) {
            if (resetCircuit) {
                store.resetCircuit()
            }
            if (store.circuitOpen()) {
                return mapOf("ok" to false, "skipped" to "circuit_open")
            }
            var pulled = 0
            var pushed = 0
            val channels = effectiveChannels()
            channels.forEach { ch ->
                when (ch.optString("mode")) {
                    "pullOnly" -> {
                        try {
                            pull.pull(ch)
                            pulled++
                        } catch (e: Exception) {
                            Log.w(
                                TAG,
                                "pull fail-open channel=${ch.optString("id")}: ${e.message}",
                            )
                        }
                    }
                    "bidirectional" ->
                        Log.w(TAG, "BIDIRECTIONAL ignored (not configured for this increment)")
                }
            }
            var pushError: Exception? = null
            channels.forEach { ch ->
                if (ch.optString("mode") != "pushOnly") return@forEach
                try {
                    pushed += push.push(ch, host)
                } catch (e: Exception) {
                    pushError = e
                    Log.e(
                        TAG,
                        "push fail-open channel=${ch.optString("id")}: ${e.message}",
                        e,
                    )
                }
            }
            if (pushError != null) {
                store.recordFailure()
                return mapOf(
                    "ok" to false,
                    "error" to (pushError?.message ?: "sync_failed"),
                    "pulled" to pulled,
                    "pushed" to pushed,
                )
            }
            store.recordSuccess()
            try {
                PluginEventStore.purgeSynced(appContext)
            } catch (e: Exception) {
                Log.w(TAG, "plugin event purge: ${e.message}")
            }
            Log.i(
                TAG,
                "runSynchronized ok pulled=$pulled pushed=$pushed endpoint=${store.endpoint()}",
            )
            return mapOf("ok" to true, "pulled" to pulled, "pushed" to pushed)
        }
    }

    /**
     * Canales built-in del plugin (settings + tabla propia) + extras de la app
     * (p. ej. boa_app.audit_logs). No se pisan por id.
     */
    private fun effectiveChannels(): List<JSONObject> {
        try {
            PluginEventStore.ensure(appContext)
        } catch (e: Exception) {
            Log.w(TAG, "plugin event store ensure: ${e.message}")
        }
        val builtin = listOf(
            JSONObject()
                .put("id", "sdk_settings")
                .put("mode", "pullOnly")
                .put("pullPath", "/v1/sdk/settings"),
            JSONObject()
                .put("id", "plugin_events")
                .put("mode", "pushOnly")
                .put("table", PluginEventStore.TABLE)
                .put("databasePath", PluginEventStore.path(appContext))
                .put("pendingColumn", "synced")
                .put("pendingValue", "0")
                .put("idColumn", "id")
                .put("pushPath", "/v1/ingest/audit-events"),
        )
        val seen = builtin.map { it.optString("id") }.toMutableSet()
        return builtin + store.channels().filter { seen.add(it.optString("id")) }
    }

    companion object {
        private const val TAG = "OmniTableSync"
        @Volatile private var instance: SyncEngine? = null

        fun get(context: Context): SyncEngine {
            return instance ?: synchronized(this) {
                instance ?: SyncEngine(context.applicationContext).also { instance = it }
            }
        }
    }
}

internal class SyncScheduler(private val context: Context) {
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private val tick = object : Runnable {
        override fun run() {
            val engine = SyncEngine.get(context)
            engine.runSynchronized()
            val delay = engine.store().intervalSec() * 1000L
            handler?.postDelayed(this, delay)
        }
    }
    private val actionTick = object : Runnable {
        override fun run() {
            val engine = SyncEngine.get(context)
            engine.actions().pollAndRun()
            val delay = engine.store().effectiveActionPollSec() * 1000L
            handler?.postDelayed(this, delay)
        }
    }

    fun schedule() {
        ensureThread()
        handler?.removeCallbacks(tick)
        handler?.removeCallbacks(actionTick)
        handler?.post(tick)
        handler?.post(actionTick)
        TableSyncWorker.enqueue(context)
    }

    /** Sync inmediato (p. ej. resume); reinicia circuit breaker y reprograma el ciclo. */
    fun triggerNow() {
        ensureThread()
        SyncEngine.get(context).store().resetCircuit()
        handler?.removeCallbacks(tick)
        handler?.removeCallbacks(actionTick)
        handler?.post {
            SyncEngine.get(context).runSynchronized()
            SyncEngine.get(context).actions().pollAndRun()
            val delay = SyncEngine.get(context).store().intervalSec() * 1000L
            handler?.postDelayed(tick, delay)
            val actionDelay = SyncEngine.get(context).store().effectiveActionPollSec() * 1000L
            handler?.postDelayed(actionTick, actionDelay)
        }
        TableSyncWorker.enqueueOneTime(context)
    }

    private fun ensureThread() {
        if (thread != null) return
        val t = HandlerThread("omni-mdm-sync")
        t.start()
        thread = t
        handler = Handler(t.looper)
    }
}
