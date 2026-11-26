package com.bgallagher.rackoon.data

import com.bgallagher.rackoon.core.OSVClient
import com.bgallagher.rackoon.core.OSVException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * OSV.dev for the opt-in vulnerability lookup (docs/security-plan.md, S3): plain HTTPS from the phone, no cookies, normal
 * certificate checks. Only package names, the release's ecosystem and versions are sent, and only when the user turned the
 * lookup on.
 */
class HttpOSVClient : OSVClient {
    override suspend fun post(url: String, body: String): String = send(url, body)
    override suspend fun get(url: String): String = send(url, null)

    private suspend fun send(url: String, body: String?): String = withContext(Dispatchers.IO) {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 20_000
            conn.useCaches = false
            conn.setRequestProperty("User-Agent", "Rackoon")
            if (body != null) {
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            if (code !in 200..299) throw OSVException("OSV.dev answered with HTTP $code.")
            conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
        } finally {
            conn.disconnect()
        }
    }
}
