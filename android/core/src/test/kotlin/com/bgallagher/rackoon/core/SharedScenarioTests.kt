package com.bgallagher.rackoon.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Runs the language-neutral behaviour scenarios in spec/scenarios/\*.json (docs/parity.md). The Swift core runs the same
 * files. A file with a `feature` runs only while that feature is done for Android in spec/features.json, so marking a
 * feature done turns its scenarios on; a file without one runs everywhere.
 */
class SharedScenarioTests {
    private data class Scenario(val file: String, val feature: String?, val subject: String, val cases: List<JsonObject>)

    private val platform = "android"

    private val subjects = setOf(
        "shell_quote", "template_fill", "action_policy", "compose_command", "stream_output", "server_input", "docker_ids",
    )

    private fun doneFeatures(): Set<String> =
        Spec.parse("features.json").jsonObject["features"]!!.jsonArray.map { it.jsonObject }.filter { f ->
            f["platforms"]!!.jsonObject[platform]!!.jsonObject["status"]!!.jsonPrimitive.content == "done"
        }.map { it["id"]!!.jsonPrimitive.content }.toSet()

    /** Every scenario file that applies to this platform. */
    private fun scenarios(): List<Scenario> {
        val done = doneFeatures()
        val files = Spec.file("scenarios").listFiles { f -> f.name.endsWith(".json") }!!.sortedBy { it.name }
        return files.mapNotNull { file ->
            val doc = Spec.parse("scenarios/${file.name}").jsonObject
            val feature = doc["feature"]?.jsonPrimitive?.content
            if (feature != null && feature !in done) return@mapNotNull null
            Scenario(file.name, feature, doc["subject"]!!.jsonPrimitive.content, doc["cases"]!!.jsonArray.map { it.jsonObject })
        }
    }

    private fun cases(subject: String): List<Pair<String, JsonObject>> =
        scenarios().filter { it.subject == subject }.flatMap { s ->
            s.cases.map { "${s.file}: ${it["name"]!!.jsonPrimitive.content}" to it }
        }

    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content
    private fun JsonObject.optStr(key: String): String? = this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.content

    @Test fun everyApplicableScenarioHasARunner() {
        for (s in scenarios()) {
            assertTrue(s.subject in subjects, "${s.file}: subject ${s.subject} has no Kotlin runner, but its feature is done on Android")
            assertTrue(s.cases.isNotEmpty(), s.file)
        }
    }

    @Test fun shellQuote() {
        for ((name, c) in cases("shell_quote")) {
            val input = c.str("input")
            val got = if (c.str("fn") == "quotePath") ShellQuote.quotePath(input) else ShellQuote.quote(input)
            assertEquals(c.optStr("expect"), got, name)
        }
    }

    @Test fun templateFill() {
        for ((name, c) in cases("template_fill")) {
            val values = c["values"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
            assertEquals(c.str("expect"), Template.fill(c.str("template"), values), name)
        }
    }

    private fun intent(value: JsonElement?): Intent? {
        if (value == null || value == JsonNull) return null
        val d = value.jsonObject
        return Intent(d.str("summary"), d.str("command"), if (d.str("risk") == "mutate") Risk.MUTATE else Risk.READ, d.optStr("preview"))
    }

    private fun outcome(body: () -> Unit): String = try {
        body()
        "ok"
    } catch (e: PolicyError.ReadOnly) {
        "read_only"
    } catch (e: PolicyError.NotConfirmed) {
        "not_confirmed"
    }

    @Test fun actionPolicy() {
        for ((name, c) in cases("action_policy")) {
            val policy = ActionPolicy(readOnly = c["readOnly"]!!.jsonPrimitive.boolean)
            var confirmation: Confirmation? = null
            intent(c["confirm"])?.let { shown ->
                val got = outcome { confirmation = policy.confirm(shown) }
                assertEquals(c.optStr("expectConfirm") ?: "ok", got, "$name (confirm)")
            }
            c["readOnlyAtRun"]?.jsonPrimitive?.booleanOrNull?.let { policy.isReadOnly = it }
            val run = assertNotNull(intent(c["run"]), name)
            assertEquals(c.str("expect"), outcome { policy.authorize(run, confirmation) }, name)
        }
    }

    @Test fun composeCommand() {
        for ((name, c) in cases("compose_command")) {
            val s = c["stack"]!!.jsonObject
            val stackName = s.str("name")
            val dir = s.optStr("workingDir")
            val files = s["configFiles"]!!.jsonArray.map { it.jsonPrimitive.content }
            val containers = s["services"]!!.jsonArray.mapIndexed { i, service ->
                DockerContainer(
                    id = "abcdef%06d".format(i), name = "$stackName-${service.jsonPrimitive.content}-1", image = "nginx",
                    state = "running", health = "none", status = "Up", ports = emptyList(), project = stackName,
                    service = service.jsonPrimitive.content, workingDir = dir, configFile = files.firstOrNull(), configFiles = files,
                )
            }
            val stack = DockerStack(stackName, dir, files.firstOrNull(), files, containers, s["standalone"]?.jsonPrimitive?.boolean ?: false)
            val action = assertNotNull(ComposeAction.entries.firstOrNull { it.raw == c.str("action") }, name)
            assertEquals(c.optStr("expect"), action.command(stack, c.optStr("service")), name)
        }
    }

    @Test fun streamOutput() {
        for ((name, c) in cases("stream_output")) {
            val parser = StreamOutputParser()
            val shown = c["chunks"]!!.jsonArray.joinToString("") { parser.push(it.jsonPrimitive.content) }
            val (rest, exitCode) = parser.finish()
            assertEquals(c.str("text"), shown + rest, name)
            assertEquals(c["exitCode"]?.jsonPrimitive?.intOrNull, exitCode, name)
        }
    }

    @Test fun serverInput() {
        for ((name, c) in cases("server_input")) {
            val problem = ServerInput.problem(c.str("host"), c.str("user"), c.str("port"))
            assertEquals(c["ok"]!!.jsonPrimitive.boolean, problem == null, "$name: ${problem ?: "accepted"}")
        }
    }

    @Test fun dockerIDs() {
        for ((name, c) in cases("docker_ids")) {
            val value = c.str("value")
            val ok = if (c.str("kind") == "container_id") DockerSession.isContainerID(value) else ComposeAction.isServiceName(value)
            assertEquals(c["ok"]!!.jsonPrimitive.boolean, ok, name)
        }
    }
}
