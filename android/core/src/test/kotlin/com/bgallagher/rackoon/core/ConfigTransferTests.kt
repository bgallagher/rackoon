package com.bgallagher.rackoon.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.Normalizer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun JsonElement.s(key: String): String = jsonObject[key]!!.jsonPrimitive.content
private fun hex(text: String): ByteArray = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

private fun outcome(read: () -> JsonElement): JsonObject = try {
    JsonObject(mapOf("document" to read()))
} catch (e: ConfigTransferException) {
    JsonObject(mapOf("error" to JsonPrimitive(e.code)))
}

private fun JsonObject.only(vararg keys: String) = JsonObject(filterKeys { it in keys })

/** The shared scenarios in spec/scenarios/config-codec.json and config-merge.json (run from SharedScenarioTests). */
object ConfigScenarios {
    fun read(input: JsonElement, source: String): ConfigDocument =
        ConfigTransfer.readDocument(input, secrets = source == "encrypted", customIcons = source != "qr")

    fun codec(cases: List<Pair<String, JsonObject>>) {
        for ((name, c) in cases) {
            when (c.s("fn")) {
                "base45" -> if (c["error"]?.jsonPrimitive?.booleanOrNull == true) {
                    assertNull(ConfigTransfer.base45Decode(c.s("text")), name)
                } else {
                    assertEquals(c.s("text"), ConfigTransfer.base45Encode(hex(c.s("hex"))), name)
                    assertEquals(c.s("hex"), ConfigTransfer.base45Decode(c.s("text"))!!.hex(), name)
                }
                "unlockCode" -> assertEquals((c["expect"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                    ConfigTransfer.normalizeUnlockCode(c.s("input")), name)
                "qrSplit" -> assertEquals(c["parts"]!!.jsonArray.map { it.jsonPrimitive.content },
                    ConfigTransfer.qrParts(hex(c.s("hex")), c.s("transferId"), c["maxPartBytes"]!!.jsonPrimitive.int), name)
                "qrCollect" -> {
                    val got = try {
                        val collector = QRCollector()
                        c["parts"]!!.jsonArray.forEach { collector.add(it.jsonPrimitive.content) }
                        JsonObject(mapOf("hex" to JsonPrimitive(collector.payload().hex())))
                    } catch (e: ConfigTransferException) {
                        JsonObject(mapOf("error" to JsonPrimitive(e.code)))
                    }
                    assertEquals(c.only("hex", "error"), got, name)
                }
                "fingerprint" -> assertEquals(c.s("expect"), ConfigTransfer.fingerprint(c.s("key")), name)
                "readDocument" -> {
                    val source = c.s("source")
                    val got = outcome { ConfigTransfer.documentJson(read(c["input"]!!, source), source == "encrypted", source != "qr") }
                    assertEquals(c.only("document", "error"), got, name)
                }
                else -> error("$name: unknown fn")
            }
        }
    }

    fun merge(cases: List<Pair<String, JsonObject>>) {
        for ((name, c) in cases) {
            val platform = c.s("platform")
            val local = ConfigTransfer.readDocument(c["local"]!!, secrets = true)
            val incoming = read(c["incoming"]!!, c.s("source"))
            val plan = ConfigTransfer.planImport(local, incoming, platform)
            val got = JsonObject(mapOf(
                "servers" to JsonArray(plan.servers.map { p ->
                    JsonObject(buildMap {
                        put("id", JsonPrimitive(p.incoming.id)); put("kind", JsonPrimitive(p.kind.key))
                        p.localId?.let { put("localId", JsonPrimitive(it)) }
                        p.matchedBy?.let { put("matchedBy", JsonPrimitive(it)) }
                        if (p.changes.isNotEmpty()) put("changes", JsonArray(p.changes.map(::JsonPrimitive)))
                    })
                }),
                "hostKeys" to JsonArray(plan.hostKeys.map {
                    JsonObject(mapOf("host" to JsonPrimitive(it.key.host), "port" to JsonPrimitive(it.key.port),
                        "type" to JsonPrimitive(it.key.type), "status" to JsonPrimitive(it.status.key)))
                }),
                "preferences" to JsonArray(plan.preferences.map(::JsonPrimitive)), "readOnlyTurnsOn" to JsonPrimitive(plan.readOnlyTurnsOn),
                "removed" to JsonArray(plan.removed.map(::JsonPrimitive)), "secrets" to JsonArray(plan.secrets.map(::JsonPrimitive)),
            ))
            assertEquals(c["plan"], got, name)
            val o = c["choices"]?.jsonObject ?: JsonObject(emptyMap())
            val choices = ConfigImportChoices(
                replace = o["replace"]?.jsonPrimitive?.booleanOrNull ?: false,
                keep = o["keep"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet(),
                applyPreferences = o["applyPreferences"]?.jsonPrimitive?.booleanOrNull ?: true,
                trustHostKeys = o["trustHostKeys"]?.jsonPrimitive?.booleanOrNull ?: true,
            )
            assertEquals(c["result"], ConfigTransfer.documentJson(ConfigTransfer.applyImport(local, incoming, plan, choices, platform)), name)
        }
    }
}

class ConfigTransferTests {
    private fun names(suffix: String) = Spec.file("fixtures/config").listFiles { f -> f.name.endsWith(suffix) }!!.map { it.name.removeSuffix(suffix) }.sorted()
    private fun expected(name: String) = Spec.parse("fixtures/config/$name.expected.json").jsonObject

    /** Every file in spec/fixtures/config (written by tools/config-fixtures from the Python core) reads the same here. */
    @Test fun fileFixtures() {
        val all = names(".rackoon")
        assertTrue(all.size >= 15)
        for (name in all) {
            val e = expected(name)
            val data = Spec.file("fixtures/config/$name.rackoon").readBytes()
            val encrypted = ConfigTransfer.isEncrypted(data)
            val got = outcome { ConfigTransfer.documentJson(ConfigTransfer.readFile(data, e["passphrase"]?.jsonPrimitive?.content), secrets = encrypted) }
            assertEquals(e.only("document", "error"), got, name)
        }
    }

    @Test fun qrFixtures() {
        for (name in names(".qr.json")) {
            val e = expected(name)
            val collector = QRCollector()
            Spec.parse("fixtures/config/$name.qr.json").jsonObject["parts"]!!.jsonArray.forEach { collector.add(it.jsonPrimitive.content) }
            val got = outcome {
                ConfigTransfer.documentJson(ConfigTransfer.readQRPayload(collector.payload(), e.s("unlockCode")), secrets = false, customIcons = false)
            }
            assertEquals(e.only("document", "error"), got, name)
        }
    }

    private fun sample(): ConfigDocument {
        val json = Spec.parse("fixtures/config/mac-plain.rackoon").jsonObject
        val second = json["servers"]!!.jsonArray[1].s("id")
        val withSecrets = JsonObject(json + ("secrets" to JsonObject(mapOf(second to JsonObject(mapOf("password" to JsonPrimitive("pässwörd")))))))
        return ConfigTransfer.readDocument(withSecrets, secrets = true)
    }

    @Test fun anEncryptedFileRoundTripsWithItsSecrets() {
        val doc = sample()
        val data = ConfigTransfer.encryptedFile(doc, "a passphrase", iterations = ConfigTransfer.MIN_ITERATIONS)
        assertTrue(ConfigTransfer.isEncrypted(data))
        assertTrue("pässwörd" !in data.toString(Charsets.UTF_8))
        assertEquals(ConfigTransfer.documentJson(doc), ConfigTransfer.documentJson(ConfigTransfer.readFile(data, "a passphrase")))
        assertEquals("needsPassphrase", assertFailsWith<ConfigTransferException> { ConfigTransfer.readFile(data) }.code)
    }

    @Test fun thePassphraseIsComparedAfterUnicodeNormalisation() {
        val doc = sample()
        val composed = "café au lait!"
        val decomposed = Normalizer.normalize(composed, Normalizer.Form.NFD)
        val data = ConfigTransfer.encryptedFile(doc, composed, iterations = ConfigTransfer.MIN_ITERATIONS)
        assertEquals(doc.servers, ConfigTransfer.readFile(data, decomposed).servers)
    }

    @Test fun pbkdf2MatchesTheRFC7914TestVector() {
        // RFC 7914 section 11: PBKDF2-HMAC-SHA256, P="passwd", S="salt", c=1, first 32 bytes.
        assertEquals("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc",
            ConfigTransfer.pbkdf2("passwd".toByteArray(), "salt".toByteArray(), 1).hex())
    }

    @Test fun aShortPassphraseIsRefused() {
        assertEquals("passphraseTooShort", assertFailsWith<ConfigTransferException> { ConfigTransfer.encryptedFile(sample(), "123456789") }.code)
        assertNull(ConfigTransfer.passphraseProblem("1234567890"))
    }

    @Test fun aPlainFileNeverCarriesSecrets() {
        val text = ConfigTransfer.plainFile(sample()).toString(Charsets.UTF_8)
        assertTrue("secrets" !in text && "pässwörd" !in text)
    }

    @Test fun aQRTransferRoundTripsWithoutSecretsOrCustomIcons() {
        val doc = sample()
        val (code, parts) = ConfigTransfer.qrExport(doc, maxPartBytes = 200)
        assertEquals(10, code.length)
        assertTrue(parts.size > 1 && parts.all { p -> p.all { it in ConfigTransfer.BASE45 || it == ':' || it == '/' } })
        val collector = QRCollector()
        parts.reversed().forEach { collector.add(it) }
        val got = ConfigTransfer.readQRPayload(collector.payload(), ConfigTransfer.formatUnlockCode(code).lowercase())
        assertTrue(got.secrets.isEmpty() && got.customIcons.isEmpty())
        assertEquals(ConfigTransfer.documentJson(doc, secrets = false, customIcons = false), ConfigTransfer.documentJson(got))
    }

    @Test fun tooMuchForQRCodesSaysSo() {
        assertEquals("tooLarge", assertFailsWith<ConfigTransferException> { ConfigTransfer.qrParts(ByteArray(100 * 450), "ABC123") }.code)
    }

    @Test fun aZipBombIsRefused() {
        val bomb = ConfigTransfer.deflate(ByteArray(ConfigTransfer.MAX_INFLATED + 10))
        assertEquals("tooLarge", assertFailsWith<ConfigTransferException> { ConfigTransfer.inflate(bomb) }.code)
        assertFailsWith<ConfigTransferException> { ConfigTransfer.inflate(byteArrayOf(1, 2, 3, 4)) }
    }

    @Test fun theBundledCatalogIsTheSpecs() {
        assertEquals(Spec.parse("config-transfer.json"), ConfigTransfer.catalog)
        assertEquals(setOf("readOnly", "theme", "vulnerabilityLookupAll"), ConfigTransfer.preferences.keys intersect setOf("readOnly", "theme", "vulnerabilityLookupAll"))
    }

    /** The Android app's saved preferences are all in the catalog (the standing rule; tools/check-spec scans every platform's source). */
    @Test fun androidSettingsAreInTheCatalog() {
        val keys = ConfigTransfer.catalog["settings"]!!.jsonArray.mapNotNull { (it.jsonObject["keys"]!!.jsonObject["android"] as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        assertTrue(keys.containsAll(listOf("prefs:theme_id", "prefs:read_only", "prefs:auto_read_only", "prefs:start_read_only",
            "prefs:highlight_output", "prefs:terminal_font_size", "prefs:osv_lookup_all", "prefs:osv_lookup_servers")), "$keys")
    }
}
