package com.omnimdm.omni_mdm.sync

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

internal class AuditHttpTransport(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .build(),
    private val maxAttempts: Int = 3,
) {
    fun get(url: String, headers: Map<String, String>): Pair<Int, String> {
        val builder = Request.Builder().url(url).get()
        headers.forEach { (k, v) -> if (v.isNotEmpty()) builder.addHeader(k, v) }
        client.newCall(builder.build()).execute().use { response ->
            return response.code to (response.body?.string().orEmpty())
        }
    }

    fun post(url: String, headers: Map<String, String>, body: String): Pair<Int, String> {
        var lastError: IOException? = null
        repeat(maxAttempts) { attempt ->
            try {
                val builder = Request.Builder()
                    .url(url)
                    .post(body.toRequestBody(JSON))
                headers.forEach { (k, v) -> if (v.isNotEmpty()) builder.addHeader(k, v) }
                client.newCall(builder.build()).execute().use { response ->
                    val payload = response.body?.string().orEmpty()
                    if (response.code in 500..599) {
                        throw IOException("server ${response.code}")
                    }
                    return response.code to payload
                }
            } catch (e: IOException) {
                lastError = e
                if (attempt < maxAttempts - 1) {
                    Thread.sleep(backoffMs(attempt))
                }
            }
        }
        throw lastError ?: IOException("audit push failed")
    }

    private fun backoffMs(attempt: Int): Long {
        val exp = 2.0.pow(attempt.toDouble()).toLong() * 400L
        return min(exp, 6_000L)
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
