package com.bgallagher.rackoon.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import java.util.zip.DataFormatException
import java.util.zip.Deflater
import java.util.zip.Inflater
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/*
 * Config transfer (spec/config-transfer.md): the `rackoon-config` document, plain and encrypted files, the QR parts and
 * the import plan. Kept in step with the Swift core (ConfigTransfer.swift) and the Python core (config_transfer.py) by
 * spec/scenarios/config-codec.json, config-merge.json and spec/fixtures/config/. The JDK has everything it needs
 * (javax.crypto, java.util.zip), so nothing is injected; the settings catalog is read from the bundled spec.
 */

/** [code] is shared by every core (spec/fixtures/config/\*.expected.json); the message is this app's own. */
class ConfigTransferException(val code: String, message: String) : Exception(message) {
    companion object {
        fun damaged(why: String) = ConfigTransferException("damaged", "This file is damaged or was not made by Rackoon ($why).")
        fun notRackoon() = ConfigTransferException("notRackoonConfig", "This is not a Rackoon configuration file.")
        fun newer() = ConfigTransferException("newerVersion", "This configuration was made by a newer version of Rackoon. Update this app and try again.")
        fun tooLarge() = ConfigTransferException("tooLarge", "This configuration is too large.")
    }
}

data class ResolvedAddress(val host: String, val user: String? = null, val port: Int? = null)

data class ConfigServer(
    val id: String,
    val name: String,
    val host: String,
    val user: String? = null,
    val port: Int? = null,
    val sshConfigAlias: String? = null,
    val identityFile: String? = null,
    val resolved: ResolvedAddress? = null,
)

data class ConfigHostKey(val host: String, val port: Int, val type: String, val key: String) {
    internal val address: String get() = "${host.lowercase()}:$port"
}

data class ConfigSignIn(val method: String, val keyName: String? = null)

data class ConfigServerSettings(
    val icons: Map<String, String> = emptyMap(),
    val services: Map<String, Boolean> = emptyMap(),
    val vulnerabilityLookup: Boolean? = null,
    val mutedAlerts: List<String> = emptyList(),
) {
    val isEmpty: Boolean get() = icons.isEmpty() && services.isEmpty() && vulnerabilityLookup == null && mutedAlerts.isEmpty()
}

data class ConfigSecret(val password: String? = null, val privateKey: String? = null, val passphrase: String? = null, val keyName: String? = null)

data class ConfigDocument(
    val servers: List<ConfigServer> = emptyList(),
    val hostKeys: List<ConfigHostKey> = emptyList(),
    val signIn: Map<String, ConfigSignIn> = emptyMap(),
    /** Catalog ids (spec/config-transfer.json, part `preferences`) with values of the catalog's type. */
    val preferences: Map<String, JsonPrimitive> = emptyMap(),
    val serverSettings: Map<String, ConfigServerSettings> = emptyMap(),
    /** The hex of a `custom:` icon id -> base64 PNG. */
    val customIcons: Map<String, String> = emptyMap(),
    val secrets: Map<String, ConfigSecret> = emptyMap(),
    val exportedAt: String? = null,
    val sourcePlatform: String? = null,
    val sourceApp: String? = null,
)

/** A transferred preference from the bundled spec/config-transfer.json. */
data class ConfigPreference(
    val id: String,
    val type: String,
    val values: List<JsonPrimitive>? = null,
    val min: Int? = null,
    val max: Int? = null,
    val maxLength: Int? = null,
) {
    /** The value if it has this preference's type and limits, else null (dropped). */
    fun accept(value: JsonElement): JsonPrimitive? {
        val p = value as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        val ok = when (type) {
            "bool" -> !p.isString && p.booleanOrNull != null
            "int" -> !p.isString && p.content.toIntOrNull()?.let { n -> (min == null || n >= min) && (max == null || n <= max) } == true
            "string" -> p.isString && (maxLength == null || p.content.codePointCount(0, p.content.length) <= maxLength)
            else -> false
        }
        if (!ok || (values != null && p !in values)) return null
        return p
    }
}

enum class ServerPlanKind(val key: String) { NEW("new"), IDENTICAL("identical"), CHANGE("change") }
enum class HostKeyStatus(val key: String) { ADD("add"), TRUSTED("trusted"), BLOCKED("blocked"), SKIPPED("skipped") }

data class ConfigServerPlan(
    /** Fitted to this platform, with its incoming id. */
    val incoming: ConfigServer,
    val kind: ServerPlanKind,
    val localId: String? = null,
    /** "id" or "address". */
    val matchedBy: String? = null,
    val changes: List<String> = emptyList(),
) {
    val resultId: String get() = localId ?: incoming.id
}

data class ConfigHostKeyPlan(val key: ConfigHostKey, val status: HostKeyStatus, val trusted: ConfigHostKey? = null)

data class ConfigImportPlan(
    val servers: List<ConfigServerPlan>,
    val hostKeys: List<ConfigHostKeyPlan>,
    /** Ids whose incoming value differs from this device's, sorted. */
    val preferences: List<String>,
    val readOnlyTurnsOn: Boolean,
    /** Local server ids that Replace everything would remove. */
    val removed: List<String>,
    /** Incoming server ids that come with a password or key. */
    val secrets: List<String>,
)

data class ConfigImportChoices(
    val replace: Boolean = false,
    /** Incoming ids of matched servers to leave as they are here (Keep mine). */
    val keep: Set<String> = emptySet(),
    val applyPreferences: Boolean = true,
    val trustHostKeys: Boolean = true,
)

/** One scanned QR part. */
class QRPart(val transferId: String, val n: Int, val total: Int, val data: ByteArray)

/** Keeps scanned QR parts until every one is in. */
class QRCollector {
    var transferId: String? = null
        private set
    var total = 0
        private set
    private val parts = mutableMapOf<Int, ByteArray>()

    /** Adds a scanned part; true when it was new. Throws for a part of another transfer. */
    fun add(text: String): Boolean {
        val part = ConfigTransfer.parsePart(text)
        val id = transferId
        if (id == null) {
            transferId = part.transferId
            total = part.total
        } else if (part.transferId != id || part.total != total) {
            throw ConfigTransferException("otherTransfer", "That code belongs to a different transfer.")
        }
        parts[part.n]?.let { old ->
            if (!old.contentEquals(part.data)) throw ConfigTransferException("partConflict", "Two different codes claim the same place. Start the scan again.")
            return false
        }
        parts[part.n] = part.data
        return true
    }

    val count: Int get() = parts.size
    val isComplete: Boolean get() = total > 0 && parts.size == total
    val missing: List<Int> get() = (1..total).filter { it !in parts }

    fun payload(): ByteArray {
        if (!isComplete) throw ConfigTransferException("missingParts", "Some codes have not been scanned yet.")
        val out = ByteArrayOutputStream()
        for (n in 1..total) out.write(parts.getValue(n))
        val data = out.toByteArray()
        if (data.size < ConfigTransfer.MIN_PAYLOAD || data[0] != ConfigTransfer.QR_PAYLOAD_VERSION) {
            throw ConfigTransferException("badPart", "These QR codes are not a Rackoon transfer this app can read.")
        }
        return data
    }
}

object ConfigTransfer {
    const val FORMAT = "rackoon-config"
    const val ENCRYPTED_FORMAT = "rackoon-config-encrypted"
    const val VERSION = 1
    val PLATFORMS = listOf("mac", "android", "ios", "web")
    val SIGN_IN_METHODS = setOf("tailscale", "key", "password", "system")
    const val ITERATIONS = 600_000
    const val MIN_ITERATIONS = 100_000
    const val MAX_ITERATIONS = 5_000_000
    const val MIN_PASSPHRASE = 10
    const val MAX_INFLATED = 16 * 1024 * 1024
    private val FILE_AAD = "rackoon-config-encrypted/1".toByteArray()
    private val QR_AAD = "rackoon-config-qr/1".toByteArray()
    const val MAX_PART_BYTES = 450
    const val MAX_PARTS = 99
    private const val SALT = 16
    private const val NONCE = 12
    private const val TAG = 16
    internal const val QR_PAYLOAD_VERSION: Byte = 1
    internal const val MIN_PAYLOAD = 1 + SALT + NONCE + TAG
    const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    const val BASE45 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
    val HOST_KEY_ORDER = listOf("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa")
    const val EVERYWHERE = "*"
    private val SERVER_FIELDS = listOf("name", "host", "user", "port", "sshConfigAlias", "identityFile")
    private val random = SecureRandom()

    // MARK: the settings catalog

    /** spec/config-transfer.json, bundled with this module. */
    val catalog: JsonObject by lazy {
        val text = ConfigTransfer::class.java.getResourceAsStream("/spec/config-transfer.json")?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("spec/config-transfer.json is missing from the module resources")
        Json.parseToJsonElement(text) as JsonObject
    }

    val preferences: Map<String, ConfigPreference> by lazy {
        (catalog["settings"] as JsonArray).map { it as JsonObject }
            .filter { it["part"].str() == "preferences" && it["transfer"].bool() == true }
            .associate { s ->
                val id = s["id"].str()!!
                id to ConfigPreference(id, s["type"].str()!!, (s["values"] as? JsonArray)?.map { it as JsonPrimitive },
                    s["min"].int(), s["max"].int(), s["maxLength"].int())
            }
    }

    // MARK: JSON helpers (strict: a string is never a number or a flag)

    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.booleanOrNull
    private fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toIntOrNull()
    private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
    private fun JsonElement?.nonEmpty(): String? = str()?.takeIf { it.isNotEmpty() }

    internal fun isBase64(text: String): Boolean =
        text.isNotEmpty() && text.length % 4 == 0 && runCatching { Base64.getDecoder().decode(text) }.isSuccess

    // MARK: reading and writing the document

    private fun port(value: JsonElement?, place: String): Int? {
        if (value == null || value is JsonNull) return null
        val n = value.int()
        if (n == null || n !in 1..65535) throw ConfigTransferException.damaged("$place has a bad port")
        return n
    }

    private fun readServer(raw: JsonElement, index: Int): ConfigServer {
        val place = "server ${index + 1}"
        val o = raw.obj() ?: throw ConfigTransferException.damaged("$place is not an object")
        val id = o["id"].str()
        val name = o["name"].str()
        val host = o["host"].str()
        if (id.isNullOrEmpty() || id.length > 100 || name == null || host.isNullOrEmpty()) {
            throw ConfigTransferException.damaged("$place needs an id, a name and a host")
        }
        val user = o["user"].nonEmpty()
        val port = port(o["port"], place)
        if (ServerInput.problem(host, user ?: "", "") != null || host != host.trim() || (user != null && user != user.trim())) {
            throw ConfigTransferException.damaged("$place has an address Rackoon cannot use")
        }
        val resolved = o["resolved"].obj()?.let { r ->
            val rHost = r["host"].str()
            val rUser = r["user"].nonEmpty()
            if (rHost.isNullOrEmpty() || ServerInput.problem(rHost, rUser ?: "", "") != null) {
                throw ConfigTransferException.damaged("$place has a resolved address Rackoon cannot use")
            }
            ResolvedAddress(rHost, rUser, port(r["port"], place))
        }
        return ConfigServer(id, name, host, user, port, o["sshConfigAlias"].nonEmpty(), o["identityFile"].nonEmpty(), resolved)
    }

    private val keyType = Regex("[a-z0-9@.-]+")
    /** A plain name or address: never a known_hosts pattern (* ? !) or list (,), which a Mac writes into ~/.ssh/known_hosts. */
    private val keyHost = Regex("[A-Za-z0-9._:-]+")
    private val customIconId = Regex("[0-9a-f]{16,64}")

    private fun readHostKey(raw: JsonElement, index: Int): ConfigHostKey {
        val place = "host key ${index + 1}"
        val o = raw.obj() ?: throw ConfigTransferException.damaged("$place is not an object")
        val port = port(o["port"], place)
        val host = o["host"].str()
        val type = o["type"].str()
        val key = o["key"].str()
        if (host.isNullOrEmpty() || !keyHost.matches(host) || port == null || type == null || !keyType.matches(type) ||
            key == null || !isBase64(key)
        ) throw ConfigTransferException.damaged("$place is incomplete")
        return ConfigHostKey(host, port, type, key)
    }

    private fun readSettings(raw: JsonElement, everywhere: Boolean): ConfigServerSettings {
        val o = raw.obj() ?: return ConfigServerSettings()
        val services = (o["services"].obj() ?: JsonObject(emptyMap())).mapNotNull { (k, v) -> v.bool()?.takeIf { k.isNotEmpty() }?.let { k to it } }.toMap()
        if (everywhere) return ConfigServerSettings(services = services)
        val icons = (o["icons"].obj() ?: JsonObject(emptyMap())).mapNotNull { (k, v) -> v.str()?.takeIf { k.isNotEmpty() }?.let { k to it } }.toMap()
        val muted = (o["mutedAlerts"] as? JsonArray)?.mapNotNull { it.str()?.takeIf(String::isNotEmpty) }?.toSortedSet()?.toList() ?: emptyList()
        return ConfigServerSettings(icons, services, o["vulnerabilityLookup"].bool(), muted)
    }

    /** Reads a parsed document. [secrets] is true only for an encrypted file; a QR transfer passes `customIcons = false`. */
    fun readDocument(json: JsonElement, secrets: Boolean, customIcons: Boolean = true): ConfigDocument {
        val o = json.obj()
        if (o == null || o["format"].str() != FORMAT) throw ConfigTransferException.notRackoon()
        val version = o["version"].int()
        if (version == null || version < 1) throw ConfigTransferException.damaged("no version")
        if (version > VERSION) throw ConfigTransferException.newer()
        val source = o["source"].obj()

        val rawServers = o["servers"] ?: JsonArray(emptyList())
        val servers = (rawServers as? JsonArray ?: throw ConfigTransferException.damaged("servers is not a list"))
            .mapIndexed { i, s -> readServer(s, i) }
        val ids = servers.map { it.id }.toSet()
        if (ids.size != servers.size) throw ConfigTransferException.damaged("two servers share an id")

        val rawKeys = o["hostKeys"] ?: JsonArray(emptyList())
        val keys = (rawKeys as? JsonArray ?: throw ConfigTransferException.damaged("hostKeys is not a list"))
            .mapIndexed { i, k -> readHostKey(k, i) }.distinct()

        val signIn = (o["signIn"].obj() ?: JsonObject(emptyMap())).mapNotNull { (id, raw) ->
            val method = raw.obj()?.get("method").str()
            if (id in ids && method != null && method in SIGN_IN_METHODS) id to ConfigSignIn(method, raw.obj()?.get("keyName").nonEmpty()) else null
        }.toMap()
        val prefs = (o["preferences"].obj() ?: JsonObject(emptyMap())).mapNotNull { (id, raw) ->
            preferences[id]?.accept(raw)?.let { id to it }
        }.toMap()
        val settings = (o["serverSettings"].obj() ?: JsonObject(emptyMap())).mapNotNull { (id, raw) ->
            if (id !in ids && id != EVERYWHERE) return@mapNotNull null
            readSettings(raw, id == EVERYWHERE).takeIf { !it.isEmpty }?.let { id to it }
        }.toMap()
        val icons = if (!customIcons) emptyMap() else (o["customIcons"].obj() ?: JsonObject(emptyMap())).mapNotNull { (id, raw) ->
            val png = raw.str()
            if (customIconId.matches(id) && png != null && isBase64(png)) id to png else null
        }.toMap()
        val secretMap = if (!secrets) emptyMap() else (o["secrets"].obj() ?: JsonObject(emptyMap())).mapNotNull { (id, raw) ->
            val r = raw.obj() ?: return@mapNotNull null
            val s = ConfigSecret(r["password"].str(), r["privateKey"].str(), r["passphrase"].str(), r["keyName"].str())
            if (id in ids && (!s.password.isNullOrEmpty() || !s.privateKey.isNullOrEmpty())) id to s else null
        }.toMap()
        return ConfigDocument(
            servers, keys, signIn, prefs, settings, icons, secretMap, o["exportedAt"].str(),
            source?.get("platform").str()?.takeIf { it in PLATFORMS }, source?.get("app").str(),
        )
    }

    private fun obj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
        JsonObject(pairs.mapNotNull { (k, v) -> v?.let { k to it } }.toMap())

    private fun s(v: String?): JsonElement? = v?.let(::JsonPrimitive)
    private fun n(v: Int?): JsonElement? = v?.let(::JsonPrimitive)

    fun serverJson(s: ConfigServer): JsonObject = obj(
        "id" to s(s.id), "name" to s(s.name), "host" to s(s.host), "user" to s(s.user), "port" to n(s.port),
        "sshConfigAlias" to s(s.sshConfigAlias), "identityFile" to s(s.identityFile),
        "resolved" to s.resolved?.let { obj("host" to s(it.host), "user" to s(it.user), "port" to n(it.port)) },
    )

    fun settingsJson(s: ConfigServerSettings): JsonObject = obj(
        "icons" to s.icons.takeIf { it.isNotEmpty() }?.let { m -> JsonObject(m.mapValues { JsonPrimitive(it.value) }) },
        "services" to s.services.takeIf { it.isNotEmpty() }?.let { m -> JsonObject(m.mapValues { JsonPrimitive(it.value) }) },
        "vulnerabilityLookup" to s.vulnerabilityLookup?.let(::JsonPrimitive),
        "mutedAlerts" to s.mutedAlerts.takeIf { it.isNotEmpty() }?.let { l -> JsonArray(l.toSortedSet().map(::JsonPrimitive)) },
    )

    /** The canonical JSON: what a file holds and what the shared fixtures and scenarios compare. */
    fun documentJson(doc: ConfigDocument, secrets: Boolean = true, customIcons: Boolean = true): JsonObject = obj(
        "format" to JsonPrimitive(FORMAT), "version" to JsonPrimitive(VERSION), "exportedAt" to s(doc.exportedAt),
        "source" to if (doc.sourcePlatform != null || doc.sourceApp != null) obj("platform" to s(doc.sourcePlatform), "app" to s(doc.sourceApp)) else null,
        "servers" to JsonArray(doc.servers.map(::serverJson)),
        "hostKeys" to JsonArray(doc.hostKeys.map { obj("host" to s(it.host), "port" to n(it.port), "type" to s(it.type), "key" to s(it.key)) }),
        "signIn" to JsonObject(doc.signIn.mapValues { obj("method" to s(it.value.method), "keyName" to s(it.value.keyName)) }),
        "preferences" to JsonObject(doc.preferences),
        "serverSettings" to JsonObject(doc.serverSettings.filterValues { !it.isEmpty }.mapValues { settingsJson(it.value) }),
        "customIcons" to if (customIcons && doc.customIcons.isNotEmpty()) JsonObject(doc.customIcons.mapValues { JsonPrimitive(it.value) }) else null,
        "secrets" to if (secrets && doc.secrets.isNotEmpty()) JsonObject(doc.secrets.mapValues { (_, v) ->
            obj("password" to s(v.password), "privateKey" to s(v.privateKey), "passphrase" to s(v.passphrase), "keyName" to s(v.keyName))
        }) else null,
    )

    // MARK: crypto and compression (JDK only)

    private fun nfc(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFC)

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    /**
     * PBKDF2-HMAC-SHA256 over the exact bytes given, 32 bytes (one block). The JDK's PBEKeySpec takes chars, and Android
     * has varied in how it encodes them, so the passphrase's NFC UTF-8 bytes are fed to HMAC directly. Never empty: a
     * passphrase has at least 10 characters and an unlock code exactly 10.
     */
    internal fun pbkdf2(password: ByteArray, salt: ByteArray, iterations: Int): ByteArray {
        require(password.isNotEmpty() && iterations >= 1)
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(password, "HmacSHA256")) }
        mac.update(salt)
        mac.update(byteArrayOf(0, 0, 0, 1))
        var u = mac.doFinal()
        val out = u.copyOf()
        repeat(iterations - 1) {
            u = mac.doFinal(u)
            for (i in out.indices) out[i] = (out[i].toInt() xor u[i].toInt()).toByte()
        }
        return out
    }

    private fun seal(key: ByteArray, nonce: ByteArray, plain: ByteArray, aad: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad)
            doFinal(plain)
        }

    /** Null when the tag does not match. */
    private fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray? = try {
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad)
            doFinal(sealed)
        }
    } catch (_: AEADBadTagException) {
        null
    }

    internal fun deflate(data: ByteArray): ByteArray {
        val d = Deflater(9, true)
        d.setInput(data)
        d.finish()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (!d.finished()) out.write(buffer, 0, d.deflate(buffer))
        d.end()
        return out.toByteArray()
    }

    internal fun inflate(data: ByteArray, limit: Int = MAX_INFLATED): ByteArray {
        val inflater = Inflater(true)
        // With nowrap, zlib may want one byte past the end of the data.
        inflater.setInput(data + 0.toByte())
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        try {
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) throw ConfigTransferException.damaged("it is cut short")
                out.write(buffer, 0, n)
                if (out.size() > limit) throw ConfigTransferException.tooLarge()
            }
        } catch (e: DataFormatException) {
            throw ConfigTransferException.damaged("it does not decompress")
        } finally {
            inflater.end()
        }
        return out.toByteArray()
    }

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    // MARK: files

    /** Why a passphrase can't be used, or null. */
    fun passphraseProblem(passphrase: String): String? {
        val p = nfc(passphrase)
        return if (p.codePointCount(0, p.length) < MIN_PASSPHRASE) "Use a passphrase of at least $MIN_PASSPHRASE characters." else null
    }

    private val pretty = Json { prettyPrint = true }

    /** The document as a plain file, which never carries secrets. */
    fun plainFile(doc: ConfigDocument): ByteArray = (pretty.encodeToString(JsonElement.serializer(), documentJson(doc, secrets = false)) + "\n").toByteArray()

    fun encryptedFile(doc: ConfigDocument, passphrase: String, iterations: Int = ITERATIONS, randomBytes: (Int) -> ByteArray = ::randomBytes): ByteArray {
        passphraseProblem(passphrase)?.let { throw ConfigTransferException("passphraseTooShort", it) }
        val salt = randomBytes(SALT)
        val nonce = randomBytes(NONCE)
        val key = pbkdf2(nfc(passphrase).toByteArray(), salt, iterations)
        val sealed = seal(key, nonce, deflate(documentJson(doc).toString().toByteArray()), FILE_AAD)
        val b64 = Base64.getEncoder()
        val envelope = obj(
            "format" to JsonPrimitive(ENCRYPTED_FORMAT), "version" to JsonPrimitive(VERSION),
            "kdf" to obj("name" to JsonPrimitive("PBKDF2-SHA256"), "iterations" to JsonPrimitive(iterations), "salt" to JsonPrimitive(b64.encodeToString(salt))),
            "cipher" to JsonPrimitive("AES-256-GCM"), "compression" to JsonPrimitive("deflate-raw"),
            "nonce" to JsonPrimitive(b64.encodeToString(nonce)), "ciphertext" to JsonPrimitive(b64.encodeToString(sealed)),
        )
        return (pretty.encodeToString(JsonElement.serializer(), envelope) + "\n").toByteArray()
    }

    private fun parse(data: ByteArray): JsonElement? = runCatching { Json.parseToJsonElement(data.toString(Charsets.UTF_8)) }.getOrNull()

    fun isEncrypted(data: ByteArray): Boolean = parse(data).obj()?.get("format").str() == ENCRYPTED_FORMAT

    /** A plain or encrypted file. An encrypted one without a passphrase throws `needsPassphrase`. */
    fun readFile(data: ByteArray, passphrase: String? = null): ConfigDocument {
        val json = parse(data) ?: throw ConfigTransferException.notRackoon()
        val o = json.obj()
        if (o == null || o["format"].str() != ENCRYPTED_FORMAT) return readDocument(json, secrets = false)
        val version = o["version"].int()
        if (version != null && version > VERSION) throw ConfigTransferException.newer()
        val kdf = o["kdf"].obj()
        if (version != VERSION || kdf == null || kdf["name"].str() != "PBKDF2-SHA256" || o["cipher"].str() != "AES-256-GCM" ||
            o["compression"].str() != "deflate-raw"
        ) throw ConfigTransferException.damaged("unknown encryption")
        val iterations = kdf["iterations"].int()
        if (iterations == null || iterations !in MIN_ITERATIONS..MAX_ITERATIONS) throw ConfigTransferException.damaged("bad key settings")
        fun b64(e: JsonElement?): ByteArray = e.str()?.takeIf { isBase64(it) }?.let { Base64.getDecoder().decode(it) }
            ?: throw ConfigTransferException.damaged("bad base64")
        val salt = b64(kdf["salt"])
        val nonce = b64(o["nonce"])
        val sealed = b64(o["ciphertext"])
        if (salt.size != SALT || nonce.size != NONCE || sealed.size < TAG) throw ConfigTransferException.damaged("bad sizes")
        if (passphrase == null) throw ConfigTransferException("needsPassphrase", "This file is encrypted. Enter its passphrase.")
        val plain = open(pbkdf2(nfc(passphrase).toByteArray(), salt, iterations), nonce, sealed, FILE_AAD)
            ?: throw ConfigTransferException("wrongPassphrase", "Wrong passphrase, or the file was changed.")
        val inner = parse(inflate(plain)) ?: throw ConfigTransferException.damaged("the contents are not JSON")
        return readDocument(inner, secrets = true)
    }

    // MARK: Base45, unlock codes, QR parts

    fun base45Encode(data: ByteArray): String {
        val sb = StringBuilder()
        var i = 0
        while (i + 1 < data.size) {
            val n = (data[i].toInt() and 0xFF) * 256 + (data[i + 1].toInt() and 0xFF)
            sb.append(BASE45[n % 45]).append(BASE45[(n / 45) % 45]).append(BASE45[n / 2025])
            i += 2
        }
        if (data.size % 2 == 1) {
            val n = data.last().toInt() and 0xFF
            sb.append(BASE45[n % 45]).append(BASE45[n / 45])
        }
        return sb.toString()
    }

    fun base45Decode(text: String): ByteArray? {
        val values = text.map { BASE45.indexOf(it).takeIf { i -> i >= 0 } ?: return null }
        if (values.size % 3 == 1) return null
        val out = ByteArrayOutputStream()
        var i = 0
        while (i < values.size) {
            if (i + 2 < values.size) {
                val n = values[i] + values[i + 1] * 45 + values[i + 2] * 2025
                if (n > 0xFFFF) return null
                out.write(n / 256); out.write(n % 256)
                i += 3
            } else {
                val n = values[i] + values[i + 1] * 45
                if (n > 0xFF) return null
                out.write(n)
                i += 2
            }
        }
        return out.toByteArray()
    }

    private fun crockford(randomBytes: (Int) -> ByteArray, count: Int): String =
        randomBytes(count).joinToString("") { CROCKFORD[it.toInt() and 31].toString() }

    fun newUnlockCode(randomBytes: (Int) -> ByteArray = ::randomBytes): String = crockford(randomBytes, 10)

    fun formatUnlockCode(code: String): String = "${code.take(5)}-${code.drop(5)}"

    /** The 10 symbols as typed (upper-cased, spaces and hyphens removed, O read as 0, I and L as 1), or null. */
    fun normalizeUnlockCode(text: String): String? {
        val s = text.uppercase().filter { it != ' ' && it != '-' && it != '\t' }
            .map { when (it) { 'O' -> '0'; 'I', 'L' -> '1'; else -> it } }.joinToString("")
        return s.takeIf { it.length == 10 && it.all { c -> c in CROCKFORD } }
    }

    fun qrParts(payload: ByteArray, transferId: String, maxPartBytes: Int = MAX_PART_BYTES): List<String> {
        val total = maxOf(1, (payload.size + maxPartBytes - 1) / maxPartBytes)
        if (total > MAX_PARTS) throw ConfigTransferException("tooLarge", "Too many servers and settings for QR codes. Export a file instead.")
        val size = (payload.size + total - 1) / total
        return (0 until total).map { n ->
            val chunk = payload.copyOfRange(minOf(n * size, payload.size), minOf((n + 1) * size, payload.size))
            "RK1:$transferId:${n + 1}/$total:${base45Encode(chunk)}"
        }
    }

    private val partPattern = Regex("RK1:([0-9A-HJKMNP-TV-Z]{6}):([1-9][0-9]?)/([1-9][0-9]?):(.*)", RegexOption.DOT_MATCHES_ALL)

    fun parsePart(text: String): QRPart {
        val m = partPattern.matchEntire(text.trim()) ?: throw ConfigTransferException("badPart", "This QR code is not part of a Rackoon transfer.")
        val n = m.groupValues[2].toInt()
        val total = m.groupValues[3].toInt()
        if (n > total) throw ConfigTransferException("badPart", "This QR code is not part of a Rackoon transfer.")
        val data = base45Decode(m.groupValues[4])?.takeIf { it.isNotEmpty() } ?: throw ConfigTransferException("badPart", "This QR code is damaged.")
        return QRPart(m.groupValues[1], n, total, data)
    }

    fun qrPayload(doc: ConfigDocument, code: String, randomBytes: (Int) -> ByteArray = ::randomBytes): ByteArray {
        val salt = randomBytes(SALT)
        val nonce = randomBytes(NONCE)
        val key = pbkdf2(code.toByteArray(), salt, ITERATIONS)
        val body = deflate(documentJson(doc, secrets = false, customIcons = false).toString().toByteArray())
        return byteArrayOf(QR_PAYLOAD_VERSION) + salt + nonce + seal(key, nonce, body, QR_AAD)
    }

    /** The unlock code and the QR texts in order. */
    fun qrExport(doc: ConfigDocument, maxPartBytes: Int = MAX_PART_BYTES, randomBytes: (Int) -> ByteArray = ::randomBytes): Pair<String, List<String>> {
        val code = newUnlockCode(randomBytes)
        val transferId = crockford(randomBytes, 6)
        return code to qrParts(qrPayload(doc, code, randomBytes), transferId, maxPartBytes)
    }

    fun readQRPayload(payload: ByteArray, typedCode: String): ConfigDocument {
        if (payload.size < MIN_PAYLOAD || payload[0] != QR_PAYLOAD_VERSION) {
            throw ConfigTransferException("badPart", "These QR codes are not a Rackoon transfer this app can read.")
        }
        val code = normalizeUnlockCode(typedCode)
            ?: throw ConfigTransferException("badUnlockCode", "An unlock code is 10 letters and digits, shown beside the QR code.")
        val salt = payload.copyOfRange(1, 1 + SALT)
        val nonce = payload.copyOfRange(1 + SALT, 1 + SALT + NONCE)
        val plain = open(pbkdf2(code.toByteArray(), salt, ITERATIONS), nonce, payload.copyOfRange(1 + SALT + NONCE, payload.size), QR_AAD)
            ?: throw ConfigTransferException("wrongUnlockCode", "Wrong unlock code.")
        val inner = parse(inflate(plain)) ?: throw ConfigTransferException.damaged("the contents are not JSON")
        return readDocument(inner, secrets = false, customIcons = false)
    }

    /** `SHA256:` and the unpadded base64 of the key's SHA-256, as `ssh-keygen -l` prints. Null for bad base64. */
    fun fingerprint(keyBase64: String): String? {
        if (!isBase64(keyBase64)) return null
        return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha256(Base64.getDecoder().decode(keyBase64)))
    }

    // MARK: import planning

    /** Rule 1: what an incoming server becomes on this platform. */
    fun fit(server: ConfigServer, platform: String): ConfigServer {
        if (platform == "mac") return server
        var s = server
        val r = s.resolved
        if (r != null) s = s.copy(host = r.host, user = r.user ?: s.user, port = r.port ?: s.port)
        return s.copy(sshConfigAlias = null, identityFile = null, resolved = null)
    }

    /** `system` (a Mac's own ssh setup) means nothing elsewhere: the server keeps its own sign-in there. */
    fun fit(signIn: ConfigSignIn?, platform: String): ConfigSignIn? =
        signIn?.takeIf { it.method != "system" || platform == "mac" }

    private data class Address(val host: String, val user: String, val port: Int)
    private fun address(s: ConfigServer) = Address(s.host.lowercase(), s.user ?: "", s.port ?: 22)

    private fun differences(local: ConfigServer, incoming: ConfigServer): List<String> = SERVER_FIELDS.filter { field ->
        when (field) {
            "name" -> local.name != incoming.name
            "host" -> local.host.lowercase() != incoming.host.lowercase()
            "user" -> (local.user ?: "") != (incoming.user ?: "")
            "port" -> (local.port ?: 22) != (incoming.port ?: 22)
            "sshConfigAlias" -> (local.sshConfigAlias ?: "") != (incoming.sshConfigAlias ?: "")
            else -> (local.identityFile ?: "") != (incoming.identityFile ?: "")
        }
    }

    private fun rank(type: String): Int = HOST_KEY_ORDER.indexOf(type).takeIf { it >= 0 } ?: HOST_KEY_ORDER.size

    fun planHostKeys(local: List<ConfigHostKey>, incoming: List<ConfigHostKey>, platform: String): List<ConfigHostKeyPlan> {
        val byAddress = local.groupBy { it.address }
        val single = platform != "mac"
        val chosen = mutableMapOf<String, ConfigHostKey>()
        if (single) {
            for (k in incoming.sortedBy { rank(it.type) }) if (k.address !in byAddress) chosen.putIfAbsent(k.address, k)
        }
        return incoming.map { k ->
            val trusted = byAddress[k.address].orEmpty()
            val sameType = trusted.filter { it.type == k.type }
            when {
                sameType.any { it.key == k.key } -> ConfigHostKeyPlan(k, HostKeyStatus.TRUSTED)
                sameType.isNotEmpty() -> ConfigHostKeyPlan(k, HostKeyStatus.BLOCKED, sameType.first())
                trusted.isNotEmpty() || (single && chosen[k.address] != k) -> ConfigHostKeyPlan(k, HostKeyStatus.SKIPPED)
                else -> ConfigHostKeyPlan(k, HostKeyStatus.ADD)
            }
        }
    }

    fun planImport(local: ConfigDocument, incoming: ConfigDocument, platform: String): ConfigImportPlan {
        val fitted = incoming.servers.map { fit(it, platform) }
        val localById = local.servers.associateBy { it.id }
        val used = mutableSetOf<String>()
        val matches = mutableMapOf<String, Pair<ConfigServer, String>>()
        for (s in fitted) localById[s.id]?.let { matches[s.id] = it to "id"; used += s.id }
        for (s in fitted) {
            if (s.id in matches) continue
            local.servers.firstOrNull { it.id !in used && address(it) == address(s) }?.let { matches[s.id] = it to "address"; used += it.id }
        }
        val plans = fitted.map { s ->
            val (here, how) = matches[s.id] ?: return@map ConfigServerPlan(s, ServerPlanKind.NEW)
            val changes = differences(here, s)
            ConfigServerPlan(s, if (changes.isEmpty()) ServerPlanKind.IDENTICAL else ServerPlanKind.CHANGE, here.id, how, changes)
        }
        val readOnlyTrue = JsonPrimitive(true)
        return ConfigImportPlan(
            plans, planHostKeys(local.hostKeys, incoming.hostKeys, platform),
            incoming.preferences.filter { (k, v) -> local.preferences[k] != v }.keys.sorted(),
            incoming.preferences["readOnly"] == readOnlyTrue && local.preferences["readOnly"] != readOnlyTrue,
            local.servers.map { it.id }.filter { it !in used },
            fitted.map { it.id }.filter { it in incoming.secrets },
        )
    }

    private fun merge(here: ConfigServerSettings?, new: ConfigServerSettings): ConfigServerSettings {
        val base = here ?: ConfigServerSettings()
        return ConfigServerSettings(
            base.icons + new.icons, base.services + new.services, new.vulnerabilityLookup ?: base.vulnerabilityLookup,
            (base.mutedAlerts + new.mutedAlerts).toSortedSet().toList(),
        )
    }

    private fun preferences(local: Map<String, JsonPrimitive>, incoming: Map<String, JsonPrimitive>): Map<String, JsonPrimitive> {
        val out = (local + incoming).toMutableMap()
        if ("readOnly" in local || "readOnly" in incoming) {
            out["readOnly"] = JsonPrimitive(local["readOnly"] == JsonPrimitive(true) || incoming["readOnly"] == JsonPrimitive(true))
        }
        return out
    }

    /**
     * The configuration after the import. Its `secrets` are only the imported ones, filed under the ids they now belong
     * to, for the app to save; `hostKeys` are this device's plus the ones added.
     */
    fun applyImport(local: ConfigDocument, incoming: ConfigDocument, plan: ConfigImportPlan, choices: ConfigImportChoices, platform: String): ConfigDocument {
        val hostKeys = local.hostKeys + if (choices.trustHostKeys) plan.hostKeys.filter { it.status == HostKeyStatus.ADD }.map { it.key } else emptyList()
        val base = ConfigDocument(
            hostKeys = hostKeys, customIcons = local.customIcons + incoming.customIcons,
            exportedAt = local.exportedAt, sourcePlatform = local.sourcePlatform, sourceApp = local.sourceApp,
        )
        val signIn = mutableMapOf<String, ConfigSignIn>()
        val settings = mutableMapOf<String, ConfigServerSettings>()
        val secrets = mutableMapOf<String, ConfigSecret>()

        if (choices.replace) {
            val here = local.servers.associateBy { it.id }
            val servers = plan.servers.map { p ->
                if (p.kind == ServerPlanKind.IDENTICAL && p.localId != null) here.getValue(p.localId) else p.incoming.copy(id = p.resultId)
            }
            for (p in plan.servers) {
                fit(incoming.signIn[p.incoming.id], platform)?.let { signIn[p.resultId] = it }
                incoming.serverSettings[p.incoming.id]?.let { settings[p.resultId] = it }
                incoming.secrets[p.incoming.id]?.let { secrets[p.resultId] = it }
            }
            incoming.serverSettings[EVERYWHERE]?.let { settings[EVERYWHERE] = it }
            return base.copy(servers = servers, signIn = signIn, serverSettings = settings, secrets = secrets,
                preferences = preferences(local.preferences, incoming.preferences))
        }

        val taken = plan.servers.filter { it.kind == ServerPlanKind.NEW || it.incoming.id !in choices.keep }
        val updated = taken.filter { it.kind == ServerPlanKind.CHANGE && it.localId != null }.associate { it.localId!! to it.incoming }
        val servers = local.servers.map { s -> updated[s.id]?.copy(id = s.id) ?: s } + plan.servers.filter { it.kind == ServerPlanKind.NEW }.map { it.incoming }
        signIn += local.signIn
        settings += local.serverSettings
        for (p in taken) {
            fit(incoming.signIn[p.incoming.id], platform)?.let { signIn[p.resultId] = it }
            incoming.serverSettings[p.incoming.id]?.let { settings[p.resultId] = merge(settings[p.resultId], it) }
            incoming.secrets[p.incoming.id]?.let { secrets[p.resultId] = it }
        }
        val prefs = if (choices.applyPreferences) {
            incoming.serverSettings[EVERYWHERE]?.let { settings[EVERYWHERE] = merge(settings[EVERYWHERE], it) }
            preferences(local.preferences, incoming.preferences)
        } else {
            local.preferences
        }
        return base.copy(servers = servers, signIn = signIn, serverSettings = settings, secrets = secrets, preferences = prefs)
    }
}
