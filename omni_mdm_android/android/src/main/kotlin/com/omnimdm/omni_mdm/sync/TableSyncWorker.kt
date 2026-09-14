package com.omnimdm.omni_mdm.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

internal class TableSyncWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {
    override fun doWork(): Result {
        return try {
            SyncEngine.get(applicationContext).runSynchronized()
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }

    companion object {
        private const val UNIQUE = "omni_mdm_table_sync"
        private const val UNIQUE_ONCE = "omni_mdm_table_sync_once"

        private fun networkConstraints(): Constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        /** Respaldo cuando el proceso no está vivo (mínimo WorkManager: 15 min). */
        fun enqueue(context: Context) {
            val request = PeriodicWorkRequestBuilder<TableSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(networkConstraints())
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                UNIQUE,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }

        /** Sync puntual con red (resume / apertura). */
        fun enqueueOneTime(context: Context) {
            val request = OneTimeWorkRequestBuilder<TableSyncWorker>()
                .setConstraints(networkConstraints())
                .build()
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                UNIQUE_ONCE,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}
