package com.bgallagher.rackoon.core

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

// Known vulnerabilities in installed packages (docs/security-plan.md, stage S3), mirroring Vulnerabilities.swift. Opt-in:
// only source package names, the OSV ecosystem and versions are sent to OSV.dev, from the phone, never from the server.

@Serializable
data class InstalledPackage(val binary: String, val version: String, val source: String, val sourceVersion: String)

@Serializable
data class PackageInventory(val os: OS, val packages: List<InstalledPackage>) {
    @Serializable
    data class OS(val id: String, val like: String, val version: String, val codename: String)

    companion object {
        val command: String get() = SpecCommands.script("security_packages")

        fun parse(output: String): PackageInventory {
            val sections = SecurityParser.sections(output)
            val os = LinkedHashMap<String, String>()
            for (line in sections["os"] ?: emptyList()) {
                val eq = line.indexOf('=')
                if (eq >= 0) os[line.substring(0, eq)] = line.substring(eq + 1).trim(' ', '\t')
            }
            val packages = (sections["packages"] ?: emptyList()).mapNotNull { line ->
                val f = line.split("\t")
                if (f.size < 4 || f[0].isEmpty() || f[1].isEmpty()) null
                else InstalledPackage(f[0], f[1], f[2].ifEmpty { f[0] }, f[3].ifEmpty { f[1] })
            }
            return PackageInventory(OS(os["id"] ?: "", os["like"] ?: "", os["version"] ?: "", os["codename"] ?: ""), packages)
        }

        suspend fun read(transport: SSHTransport): PackageInventory {
            val result = transport.run(command, 20_000)
            if (result.exitCode != 0) throw SessionError.CommandFailed(result.exitCode, result.stderr.trim())
            return parse(result.stdout)
        }
    }
}

object DebianVersion {
    /** dpkg's ordering: -1, 0 or 1. */
    fun compare(a: String, b: String): Int {
        val (ea, ua, ra) = split(a)
        val (eb, ub, rb) = split(b)
        if (ea != eb) return if (ea < eb) -1 else 1
        val u = part(ua, ub)
        return if (u != 0) u else part(ra, rb)
    }

    private fun split(v: String): Triple<Int, String, String> {
        var rest = v
        var epoch = 0
        val colon = rest.indexOf(':')
        if (colon >= 0) rest.substring(0, colon).toIntOrNull()?.takeIf { rest.substring(0, colon).all { it.isDigit() } }?.let {
            epoch = it
            rest = rest.substring(colon + 1)
        }
        val dash = rest.lastIndexOf('-')
        return if (dash >= 0) Triple(epoch, rest.substring(0, dash), rest.substring(dash + 1)) else Triple(epoch, rest, "")
    }

    private fun digit(c: Char) = c in '0'..'9'

    private fun order(c: Char?): Int = when {
        c == null || digit(c) -> 0
        c == '~' -> -1
        c in 'a'..'z' || c in 'A'..'Z' -> c.code
        else -> c.code + 256
    }

    private fun part(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length || j < b.length) {
            var first = 0
            while ((i < a.length && !digit(a[i])) || (j < b.length && !digit(b[j]))) {
                val ac = order(a.getOrNull(i))
                val bc = order(b.getOrNull(j))
                if (ac != bc) return if (ac < bc) -1 else 1
                i++; j++
            }
            while (i < a.length && a[i] == '0') i++
            while (j < b.length && b[j] == '0') j++
            while (i < a.length && digit(a[i]) && j < b.length && digit(b[j])) {
                if (first == 0) first = a[i] - b[j]
                i++; j++
            }
            if (i < a.length && digit(a[i])) return 1
            if (j < b.length && digit(b[j])) return -1
            if (first != 0) return if (first < 0) -1 else 1
        }
        return 0
    }
}

data class OSVQuery(val name: String, val ecosystem: String, val version: String)

data class OSVRecord(
    val id: String,
    val modified: String,
    val summary: String,
    val aliases: List<String>,
    val ubuntuPriority: String?,
    val affected: List<Affected>,
) {
    data class Affected(val ecosystem: String, val name: String, val fixed: List<String>)
}

class OSVException(message: String) : Exception(message)

object OSV {
    const val BATCH_URL = "https://api.osv.dev/v1/querybatch"
    const val BATCH_SIZE = 500
    fun recordUrl(id: String): String = "https://api.osv.dev/v1/vulns/" + java.net.URLEncoder.encode(id, "UTF-8").replace("+", "%20")

    fun ecosystem(id: String, version: String): String? {
        val parts = if (version.isEmpty()) emptyList() else version.split(".")
        return when (id) {
            "ubuntu" -> {
                if (parts.size != 2 || parts.any { p -> p.isEmpty() || !p.all { it.isDigit() } }) null
                else if (parts[1] == "04" && parts[0].toInt() % 2 == 0) "Ubuntu:$version:LTS" else "Ubuntu:$version"
            }
            "debian" -> parts.firstOrNull()?.takeIf { p -> p.isNotEmpty() && p.all { it.isDigit() } }?.let { "Debian:$it" }
            else -> null
        }
    }

    fun queries(inventory: PackageInventory): List<OSVQuery> {
        val eco = ecosystem(inventory.os.id, inventory.os.version) ?: return emptyList()
        return inventory.packages.map { OSVQuery(it.source, eco, it.sourceVersion) }.toSet()
            .sortedWith(compareBy({ it.name }, { it.version }))
    }

    fun batchBody(queries: List<OSVQuery>, pageTokens: List<String?>? = null): String = buildJsonObject {
        put("queries", buildJsonArray {
            queries.forEachIndexed { i, q ->
                add(buildJsonObject {
                    put("package", buildJsonObject { put("ecosystem", q.ecosystem); put("name", q.name) })
                    pageTokens?.getOrNull(i)?.let { put("page_token", it) }
                    put("version", q.version)
                })
            }
        })
    }.toString()

    data class BatchResult(val ids: List<List<String>>, val pageTokens: List<String?>)

    fun parseBatch(text: String, count: Int): BatchResult {
        val doc = Json.parseToJsonElement(text) as? JsonObject ?: throw OSVException("not an object")
        val results = (doc["results"] as? JsonArray)?.map { it as? JsonObject ?: JsonObject(emptyMap()) } ?: emptyList()
        if (results.size != count) throw OSVException("expected $count results, got ${results.size}")
        return BatchResult(
            results.map { r -> (r["vulns"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.get("id")?.jsonPrimitive?.contentOrNull } ?: emptyList() },
            results.map { (it["next_page_token"] as? JsonPrimitive)?.contentOrNull },
        )
    }

    fun parseRecord(text: String): OSVRecord {
        val doc = Json.parseToJsonElement(text) as? JsonObject ?: throw OSVException("not an object")
        val id = (doc["id"] as? JsonPrimitive)?.contentOrNull ?: throw OSVException("no id")
        fun str(o: JsonObject, key: String) = (o[key] as? JsonPrimitive)?.contentOrNull
        val priority = (doc["severity"] as? JsonArray)?.mapNotNull { it as? JsonObject }?.firstOrNull { str(it, "type") == "Ubuntu" }
            ?.let { str(it, "score") }
        val affected = (doc["affected"] as? JsonArray)?.mapNotNull { a ->
            val o = a as? JsonObject ?: return@mapNotNull null
            val pkg = o["package"] as? JsonObject ?: return@mapNotNull null
            val eco = str(pkg, "ecosystem") ?: return@mapNotNull null
            val name = str(pkg, "name") ?: return@mapNotNull null
            val fixed = (o["ranges"] as? JsonArray)?.mapNotNull { it as? JsonObject }?.filter { str(it, "type") == "ECOSYSTEM" }
                ?.flatMap { r -> (r["events"] as? JsonArray)?.mapNotNull { e -> (e as? JsonObject)?.let { str(it, "fixed") } } ?: emptyList() }
                ?: emptyList()
            OSVRecord.Affected(eco, name, fixed)
        } ?: emptyList()
        return OSVRecord(
            id, str(doc, "modified") ?: "", str(doc, "summary") ?: "",
            (doc["aliases"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList(),
            priority?.lowercase(), affected,
        )
    }
}

data class PendingPackage(val name: String, val newVersion: String)

data class VulnerabilityFinding(
    val id: String,
    val packageName: String,
    val installed: String,
    val fixed: String?,
    val status: Status,
    /** OSV's Ubuntu priority, or "unrated". */
    val severity: String,
    val summary: String,
    val aliases: List<String>,
    val binaries: List<String>,
) {
    enum class Status(val raw: String) { FIX_WAITING("fix_waiting"), FIX_RELEASED("fix_released"), NO_FIX("no_fix") }
}

object VulnerabilityReport {
    val severities = listOf("critical", "high", "medium", "low", "negligible", "unrated")

    fun build(
        inventory: PackageInventory, queries: List<OSVQuery>, ids: List<List<String>>, records: Map<String, OSVRecord>,
        pending: List<PendingPackage>,
    ): List<VulnerabilityFinding> {
        val binaries = inventory.packages.groupBy({ it.source }, { it.binary })
        val newVersion = LinkedHashMap<String, String>().also { m -> pending.forEach { m.putIfAbsent(it.name, it.newVersion) } }
        val out = mutableListOf<VulnerabilityFinding>()
        val seen = mutableSetOf<String>()
        for ((query, list) in queries.zip(ids)) {
            for (id in list) {
                if (!seen.add("${query.name}|$id")) continue
                val record = records[id] ?: continue
                val affected = record.affected.firstOrNull { it.ecosystem == query.ecosystem && it.name == query.name } ?: continue
                val fixed = affected.fixed.filter { DebianVersion.compare(it, query.version) > 0 }
                    .minWithOrNull { x, y -> DebianVersion.compare(x, y) }
                if (fixed == null && affected.fixed.isNotEmpty()) continue
                val bins = (binaries[query.name] ?: emptyList()).sorted()
                val status = when {
                    fixed == null -> VulnerabilityFinding.Status.NO_FIX
                    bins.any { b -> newVersion[b]?.let { DebianVersion.compare(it, fixed) >= 0 } == true } -> VulnerabilityFinding.Status.FIX_WAITING
                    else -> VulnerabilityFinding.Status.FIX_RELEASED
                }
                val priority = record.ubuntuPriority?.takeIf { it in severities } ?: "unrated"
                out.add(VulnerabilityFinding(id, query.name, query.version, fixed, status, priority, record.summary, record.aliases, bins))
            }
        }
        return out.sortedWith(compareBy({ it.status.ordinal }, { severities.indexOf(it.severity) }, { it.id }))
    }
}

/** The network, injected: the app uses its HTTP client, tests replay spec/osv. */
interface OSVClient {
    suspend fun post(url: String, body: String): String
    suspend fun get(url: String): String
}

/** OSV answers for a day. */
class OSVCache {
    private val answers = HashMap<OSVQuery, Pair<List<String>, Long>>()
    private val records = HashMap<String, Pair<OSVRecord, Long>>()

    @Synchronized fun ids(q: OSVQuery, now: Long): List<String>? = answers[q]?.takeIf { now - it.second < LIFETIME_MILLIS }?.first
    @Synchronized fun store(q: OSVQuery, ids: List<String>, now: Long) { answers[q] = ids to now }
    @Synchronized fun record(id: String, now: Long): OSVRecord? = records[id]?.takeIf { now - it.second < LIFETIME_MILLIS }?.first
    @Synchronized fun store(r: OSVRecord, now: Long) { records[r.id] = r to now }

    companion object { const val LIFETIME_MILLIS = 86_400_000L }
}

object VulnerabilityLookup {
    suspend fun run(
        inventory: PackageInventory, pending: List<PendingPackage>, client: OSVClient, cache: OSVCache,
        now: Long = System.currentTimeMillis(), concurrency: Int = 8,
    ): List<VulnerabilityFinding> {
        val queries = OSV.queries(inventory)
        val ids = MutableList(queries.size) { emptyList<String>() }
        val ask = mutableListOf<Int>()
        queries.forEachIndexed { i, q -> cache.ids(q, now)?.let { ids[i] = it } ?: ask.add(i) }
        for (chunk in ask.chunked(OSV.BATCH_SIZE)) {
            var open = chunk
            var tokens: List<String?>? = null
            while (open.isNotEmpty()) {
                val qs = open.map { queries[it] }
                val result = OSV.parseBatch(client.post(OSV.BATCH_URL, OSV.batchBody(qs, tokens)), qs.size)
                val next = mutableListOf<Int>()
                val nextTokens = mutableListOf<String?>()
                open.forEachIndexed { k, i ->
                    ids[i] = ids[i] + result.ids[k]
                    result.pageTokens[k]?.let { next.add(i); nextTokens.add(it) }
                }
                open = next
                tokens = nextTokens
            }
            for (i in chunk) cache.store(queries[i], ids[i], now)
        }
        val records = HashMap<String, OSVRecord>()
        val missing = mutableListOf<String>()
        for (id in ids.flatten().toSortedSet()) cache.record(id, now)?.let { records[id] = it } ?: missing.add(id)
        val gate = Semaphore(maxOf(1, concurrency))
        coroutineScope {
            missing.map { id -> async { gate.withPermit { OSV.parseRecord(client.get(OSV.recordUrl(id))) } } }.awaitAll()
        }.forEach { records[it.id] = it; cache.store(it, now) }
        return VulnerabilityReport.build(inventory, queries, ids, records, pending)
    }
}
