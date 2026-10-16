package com.bgallagher.rackoon.ssh

import com.bgallagher.rackoon.core.ComposeAction
import com.bgallagher.rackoon.core.DockerParser
import com.bgallagher.rackoon.core.DockerSession
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.OverviewParser
import com.bgallagher.rackoon.core.SpecCommands
import com.bgallagher.rackoon.core.StreamOutputParser
import com.bgallagher.rackoon.core.StreamedCommand
import com.bgallagher.rackoon.core.UpdatesParser
import com.bgallagher.rackoon.core.UpdatesSession
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File
import java.util.Base64
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The checks in spec/integration/checks.json, run with the real sshj transport against the integration lab (test/lab;
 * `tools/lab up`, then `eval "$(tools/lab env)"`). Skipped when the lab is not configured. Like the shared scenarios, a
 * check runs only while its feature is done for Android in spec/features.json. The lab's host key is read from the
 * known_hosts file tools/lab scanned, never trusted on first use.
 */
class LabIntegrationTests {
    private val platform = "android"
    private val spec = File(System.getProperty("rackoon.spec") ?: error("rackoon.spec is not set (run the tests through Gradle)"))
    private fun json(path: String): JsonObject = Json.parseToJsonElement(File(spec, path).readText()).jsonObject
    private val checks = json("integration/checks.json")
    private val facts = checks["lab"]!!.jsonObject
    private fun fact(key: String) = facts[key]!!.jsonPrimitive.content
    private fun factList(key: String) = facts[key]!!.jsonArray.map { it.jsonPrimitive.content }

    private val implemented = setOf(
        "overview_parses", "updates_parse", "docker_parses", "stream_exit_status", "logs_cancel_leaves_nothing", "hostkey_mismatch_blocked",
    )

    private fun applicableChecks(): List<String> {
        val done = json("features.json")["features"]!!.jsonArray.map { it.jsonObject }.filter { f ->
            f["platforms"]!!.jsonObject[platform]!!.jsonObject["status"]!!.jsonPrimitive.content == "done"
        }.map { it["id"]!!.jsonPrimitive.content }.toSet()
        return checks["checks"]!!.jsonArray.map { it.jsonObject }.filter { it["feature"]!!.jsonPrimitive.content in done }
            .map { it["id"]!!.jsonPrimitive.content }
    }

    private class Lab(val host: String, val port: Int, val user: String, val key: String, val hostKey: HostKeyInfo)

    private fun lab(check: String): Lab {
        val env = System.getenv()
        assumeTrue(env["RACKOON_LAB"] == "1", "integration lab not configured (tools/lab up, then eval \"\$(tools/lab env)\")")
        assumeTrue(check in applicableChecks(), "$check: its feature is not done on Android")
        val port = env["RACKOON_LAB_PORT"]?.toIntOrNull() ?: 2222
        // One line from ssh-keyscan: "[127.0.0.1]:2222 ssh-ed25519 AAAA..."
        val (_, type, b64) = File(env["RACKOON_LAB_KNOWN_HOSTS"]!!).readLines().first { it.isNotBlank() && !it.startsWith("#") }.trim().split(' ')
        return Lab(env["RACKOON_LAB_HOST"]!!, port, env["RACKOON_LAB_USER"] ?: "rk", File(env["RACKOON_LAB_KEY"]!!).readText(),
            HostKeyInfo(type, Base64.getDecoder().decode(b64)))
    }

    private fun connect(lab: Lab, hostKey: HostKeyInfo = lab.hostKey): SshjTransport {
        val known = InMemoryKnownHosts().apply { trust(lab.host, lab.port, hostKey) }
        return SshjTransport(SshEndpoint(lab.host, lab.port, lab.user, SshAuth.PrivateKey(lab.key)), known)
    }

    private suspend fun labStack(t: SshjTransport): DockerStack {
        val result = t.run(DockerSession.command, 60_000)
        assertEquals(0, result.exitCode, result.stderr)
        return assertNotNull(DockerParser.parse(result.stdout).stacks.firstOrNull { it.name == fact("stack") }, "labstack not found")
    }

    @Test fun everyApplicableCheckHasARunner() {
        for (id in applicableChecks()) assertTrue(id in implemented, "$id has no Kotlin lab runner, but its feature is done on Android")
    }

    @Test fun overviewParses() = runBlocking<Unit> {
        val lab = lab("overview_parses")
        connect(lab).use { t ->
            val result = t.run(SpecCommands.script("overview"), 30_000)
            assertEquals(0, result.exitCode, result.stderr)
            val overview = OverviewParser.parse(result.stdout)
            assertTrue(overview.hostname.isNotEmpty())
            assertTrue(overview.disks.isNotEmpty())
            assertTrue(overview.cpu.total > 0)
            assertTrue(overview.rebootRequired)
            assertEquals(fact("tailscaleIP"), overview.tailscaleIP)
            assertEquals(factList("pending").size, overview.pendingUpdates)
            assertEquals(factList("security").size, overview.securityUpdates)
        }
    }

    @Test fun updatesParse() = runBlocking<Unit> {
        val lab = lab("updates_parse")
        connect(lab).use { t ->
            val result = t.run(UpdatesSession.command, 60_000)
            assertEquals(0, result.exitCode, result.stderr)
            val snapshot = UpdatesParser.parse(result.stdout)
            assertEquals(factList("pending"), snapshot.packages.map { it.name }.sorted())
            assertEquals(factList("security"), snapshot.packages.filter { it.isSecurity }.map { it.name }.sorted())
            assertTrue(snapshot.rebootRequired)
        }
    }

    @Test fun dockerParses() = runBlocking<Unit> {
        val lab = lab("docker_parses")
        connect(lab).use { t ->
            val stack = labStack(t)
            val ticker = assertNotNull(stack.containers.firstOrNull { it.service == fact("service") })
            assertEquals("running", ticker.state)
            assertNotNull(ComposeAction.entries.first { it.raw == "up" }.command(stack))
        }
    }

    @Test fun streamExitStatus() = runBlocking<Unit> {
        val lab = lab("stream_exit_status")
        connect(lab).use { t ->
            val text = withTimeout(30_000) { t.stream(StreamedCommand.wrap("echo lab-out; exit 3", 80, 24)).toList().joinToString("") }
            val parser = StreamOutputParser()
            val shown = parser.push(text)
            val (rest, exitCode) = parser.finish()
            assertEquals(3, exitCode, text)
            assertTrue((shown + rest).contains("lab-out"))
        }
    }

    @Test fun logsCancelLeavesNothing() = runBlocking<Unit> {
        val lab = lab("logs_cancel_leaves_nothing")
        connect(lab).use { t ->
            val ticker = labStack(t).containers.first()
            val command = assertNotNull(DockerSession.logsCommand(ticker.id))
            var seen = ""
            // `first` cancels the flow once a line arrived: the transport sends Ctrl-C through the pty, then closes.
            withTimeout(30_000) { t.stream(command).first { seen += it; seen.contains("tick") } }
            var left = "?"
            repeat(10) {
                if (left == "0") return@repeat
                delay(500)
                // `[l]` keeps the pattern from matching the shell that runs pgrep itself.
                left = t.run("pgrep -f 'docker [l]ogs -f' | wc -l", 15_000).stdout.trim()
            }
            assertEquals("0", left, "docker logs is still running on the server after cancelling")
        }
    }

    @Test fun hostKeyMismatchBlocked() = runBlocking<Unit> {
        val lab = lab("hostkey_mismatch_blocked")
        val wrong = HostKeyInfo(lab.hostKey.keyType, lab.hostKey.blob.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() })
        val marker = "/tmp/rk-lab-hostkey-${UUID.randomUUID()}"
        connect(lab, wrong).use { t -> assertFailsWith<Exception> { t.run("touch $marker", 20_000) } }
        connect(lab).use { t ->
            assertEquals("absent", t.run("test -e $marker && echo present || echo absent", 15_000).stdout.trim())
        }
    }
}
