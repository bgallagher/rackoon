package com.bgallagher.rackoon.demo

import com.bgallagher.rackoon.core.CommandResult
import com.bgallagher.rackoon.core.SessionEnd
import com.bgallagher.rackoon.core.SpecCommands
import com.bgallagher.rackoon.ssh.ServerConnection
import com.bgallagher.rackoon.ssh.ShellSession
import com.bgallagher.rackoon.ssh.SshException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
import java.util.Base64
import kotlin.random.Random

/**
 * A fake connection to a [DemoWorld]. It answers the exact commands the app sends (the same scripts the real server gets, read
 * from the spec) with made-up output, and applies what an action would do to the world, so the list and the stack page react.
 * Nothing leaves the phone.
 */
class DemoConnection(private val world: DemoWorld) : ServerConnection {
    private fun check() {
        if (world.unreachable) throw SshException.Unreachable("timed out after 10 s")
        if (world.refusesLogin) throw SshException.AuthFailed("Exhausted available authentication methods")
    }

    override suspend fun connect() { delay(120); check() }

    override fun close() {}

    override suspend fun run(command: String, timeoutMillis: Long): CommandResult {
        check()
        delay(160)
        return handle(command)
    }

    private fun handle(command: String): CommandResult {
        val inner = unwrap(command)
        return when {
            command == SpecCommands.script("overview") -> CommandResult(world.overviewOutput())
            command == SpecCommands.script("docker") -> CommandResult(world.dockerOutput())
            command == SpecCommands.script("updates") -> CommandResult(world.updatesOutput())
            command == SpecCommands.script("security") -> CommandResult(DemoSecurity.output(world.hostname))
            command == SpecCommands.script("security_packages") -> CommandResult(DemoSecurity.packages(world.hostname))
            command == SpecCommands.script("boot_id") -> CommandResult(world.bootId + "\n")
            command == SpecCommands.script("reboot") -> { world.reboot(); CommandResult("##rebooting\n") }
            command.startsWith("timeout 20 docker manifest inspect") -> CommandResult(if (command.contains("nope") || command.contains("missing")) "notfound\n" else "found\n")
            command == "ss -H -tln 2>/dev/null" -> CommandResult("LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:5001 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:3000 0.0.0.0:*\n")
            command.startsWith("T=\$(mktemp -d)") -> checkNew(command)
            command.startsWith("D=") && command.contains("##created") -> createStack(command)
            command.startsWith("F='") && command.contains("echo '##meta'") -> CommandResult(world.readFile(path(command)))
            command.contains(".rackoon-check.") -> validate(command)
            command.contains("echo '##saved'") -> save(command)
            else -> plan(inner)?.let { p -> p.effect(); CommandResult(p.lines.joinToString("\n") + "\n") } ?: CommandResult("")
        }
    }

    // MARK: files

    private fun path(command: String) = Regex("""F='([^']*)'""").find(command)?.groupValues?.get(1).orEmpty()

    private fun content(command: String): String {
        val b64 = Regex("""echo '([A-Za-z0-9+/=]*)' \| base64 -d""").find(command)?.groupValues?.get(1).orEmpty()
        return if (b64.isEmpty()) "" else String(Base64.getDecoder().decode(b64))
    }

    private fun b64After(command: String, target: String): String? =
        Regex("echo '([A-Za-z0-9+/=]*)' \\| base64 -d > " + Regex.escape("\"\$$target\"")).find(command)?.groupValues?.get(1)?.let { if (it.isEmpty()) "" else String(Base64.getDecoder().decode(it)) }

    private fun checkNew(command: String): CommandResult {
        val compose = b64After(command, "T/compose.yaml").orEmpty()
        return if (compose.contains("imagee")) CommandResult("failed to parse compose.yaml: did not find expected key\n", exitCode = 1) else CommandResult("")
    }

    /** `stack_create`: makes the folder and writes the files (the stack has no containers until `up -d`). */
    private fun createStack(command: String): CommandResult {
        val dir = Regex("""^D='([^']*)'""").find(command)?.groupValues?.get(1) ?: return CommandResult("", exitCode = 7)
        if (world.files.keys.any { it.startsWith("$dir/") }) return CommandResult("##exists\n", exitCode = 3)
        val compose = b64After(command, "D/compose.yaml").orEmpty()
        if (compose.contains("imagee")) return CommandResult("##invalid\nfailed to parse compose.yaml: did not find expected key\n", exitCode = 4)
        world.files["$dir/compose.yaml"] = compose
        b64After(command, "D/.env")?.let { world.files["$dir/.env"] = it }
        world.stackDirs[dir.substringAfterLast('/')] = dir
        return CommandResult("##created\n")
    }

    private fun validate(command: String): CommandResult =
        if (content(command).contains("imagee")) CommandResult("validating compose.yaml: services.web.imagee false schema\n", exitCode = 1) else CommandResult("")

    private fun save(command: String): CommandResult {
        val text = content(command)
        if (text.contains("imagee")) return CommandResult("##invalid\nvalidating compose.yaml: services.web.imagee false schema\n", exitCode = 4)
        val expected = Regex("""= '([0-9a-f]{64})' \]""").find(command)?.groupValues?.get(1)
        val (out, code) = world.writeFile(path(command), expected, text)
        return CommandResult(out, exitCode = code)
    }

    // MARK: actions

    private class Plan(val lines: List<String>, val effect: () -> Unit)

    /** `stream_wrap` runs the real command inside `( … )`; unwrap it so streamed and plain runs are handled the same. */
    private fun unwrap(command: String): String =
        Regex("""stty cols \d+ rows \d+ 2>/dev/null; \( (.*) \); rk=""", RegexOption.DOT_MATCHES_ALL).find(command)?.groupValues?.get(1) ?: command

    private fun tick(text: String) = "\u001B[32m✔\u001B[0m $text"

    private fun plan(inner: String): Plan? {
        if (inner.contains("apt-get update")) {
            return Plan(listOf("Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease", "Get:2 http://archive.ubuntu.com/ubuntu noble-updates InRelease [126 kB]",
                "Get:3 http://security.ubuntu.com/ubuntu noble-security InRelease [126 kB]", "Fetched 252 kB in 1s (310 kB/s)", "Reading package lists... Done")) {
                world.refreshedAt = System.currentTimeMillis() / 1000
            }
        }
        Regex("""apt-get (upgrade -y|install --only-upgrade -y) -o Dpkg::Options::=--force-confold ?(.*)$""").find(inner)?.let { m ->
            val names = if (m.groupValues[1].startsWith("install")) m.groupValues[2].trim().split(' ').filter { it.isNotEmpty() } else null
            val chosen = world.pending.filter { names == null || it.name in names }
            return Plan(
                listOf("Reading package lists... Done", "Building dependency tree... Done", "The following packages will be upgraded:", "  ${chosen.joinToString(" ") { it.name }}",
                    "${chosen.size} upgraded, 0 newly installed, 0 to remove.") +
                    chosen.flatMap { listOf("Preparing to unpack .../${it.name}_${it.newVersion}_amd64.deb ...", tick("Setting up ${it.name} (${it.newVersion})")) },
            ) { world.applyUpgrade(names) }
        }
        Regex("""docker (start|stop|restart) ([0-9a-f]{12,64})""").find(inner)?.let { m ->
            val verb = m.groupValues[1]
            val c = world.containers.firstOrNull { it.id.startsWith(m.groupValues[2]) }
                ?: return Plan(listOf("Error response from daemon: No such container: ${m.groupValues[2]}"), {})
            return Plan(listOf(c.name)) {
                when (verb) {
                    "stop" -> c.state = "exited"
                    else -> { c.state = "running"; c.startedAt = System.currentTimeMillis(); if (c.health == "unhealthy") c.health = "none" }
                }
            }
        }
        // A standalone container's own actions (docker run, no compose project): pull its image, or delete it.
        Regex("""^docker pull '([^']+)'$""").find(inner)?.let { m ->
            val image = m.groupValues[1]
            return Plan(listOf("${image.substringAfterLast(':')}: Pulling from ${image.substringBeforeLast(':')}", "Digest: sha256:5f3c8d1b0e7a", "Status: Image is up to date for $image")) {}
        }
        Regex("""^docker rm -f(?: -v)? ([0-9a-f]{12,64})$""").find(inner)?.let { m ->
            val c = world.containers.firstOrNull { it.id.startsWith(m.groupValues[1]) }
                ?: return Plan(listOf("Error response from daemon: No such container: ${m.groupValues[1]}"), {})
            return Plan(listOf(c.id)) { world.containers.remove(c) }
        }
        Regex("""docker compose -p (\S+) .*? down --remove-orphans""").find(inner)?.let { d ->
            val project = d.groupValues[1]
            val members = world.containers.filter { it.project == project }
            val folder = inner.contains("rm -rf --")
            return Plan(
                members.flatMap { listOf(" Container ${it.name}  Stopped", tick("Container ${it.name}  Removed")) } + tick("Network ${project}_default  Removed") +
                    if (folder) listOf("Removing ${world.dir(project)}") else emptyList(),
            ) {
                world.containers.removeAll { it.project == project }
                if (folder) world.files.keys.removeAll { it.startsWith(world.dir(project) + "/") }
            }
        }
        val m = Regex("""docker compose -p (\S+) .*?(pull|restart|up -d --build --no-deps (\S+)|up -d --build|up -d --force-recreate|up -d)\s*$""").find(inner) ?: return null
        val project = m.groupValues[1]
        val verb = m.groupValues[2]
        val members = world.containers.filter { it.project == project }.let { all -> if (m.groupValues[3].isNotEmpty()) all.filter { it.service == m.groupValues[3] } else all }
        return when {
            verb == "pull" -> Plan(listOf("[+] Pulling ${members.size}/${members.size}") + members.map { tick("${it.service} Pulled") }) {}
            verb == "restart" -> Plan(members.flatMap { listOf(" Container ${it.name}  Restarting", tick("Container ${it.name}  Started")) }) {
                members.forEach { it.startedAt = System.currentTimeMillis(); it.state = "running" }
            }
            else -> {
                val recreate = verb.contains("--force-recreate") || verb.contains("--build")
                Plan(
                    members.flatMap { c ->
                        if (recreate || c.state != "running") listOf(" Container ${c.name}  Recreate", tick("Container ${c.name}  Started"))
                        else listOf(" Container ${c.name}  Running")
                    },
                ) {
                    members.forEach { c ->
                        if (recreate || c.state != "running") { c.id = world.freshId(); c.startedAt = System.currentTimeMillis(); c.state = "running" }
                    }
                    world.applyCompose(project)
                }
            }
        }
    }

    override fun stream(command: String): Flow<String> = flow {
        check()
        val inner = unwrap(command)
        Regex("""docker logs -f --tail \d+ ([0-9a-f]{12,64})""").find(inner)?.let { m ->
            val c = world.containers.firstOrNull { it.id.startsWith(m.groupValues[1]) }
            val random = Random(c?.name.hashCode())
            emit((1..30).joinToString("") { DemoLogs.line(c?.name ?: "demo", random, 30 - it) + "\r\n" })
            while (true) { delay(1300); emit(DemoLogs.line(c?.name ?: "demo", random, 0) + "\r\n") }
        }
        val plan = plan(inner)
        if (plan == null) {
            emit("(demo) nothing to run for this command\r\n")
        } else {
            for (line in plan.lines) { delay(450); emit(line + "\r\n") }
            plan.effect()
            delay(200)
        }
        emit("\r\n##rackoon-exit:0\r\n")
    }

    override suspend fun openShell(cols: Int, rows: Int, command: String?): ShellSession {
        check()
        val target = command?.let { Regex("""docker exec -it ([0-9a-f]{12,64})""").find(it)?.groupValues?.get(1) }
            ?.let { id -> world.containers.firstOrNull { it.id.startsWith(id) }?.name }
        return DemoShell(world, target)
    }
}

/** Plausible log lines for the demo, with a timestamp, a level and a message. */
object DemoLogs {
    private val messages = listOf(
        "INFO" to "GET /health 200 2ms", "INFO" to "Background saving started", "INFO" to "DB saved on disk",
        "INFO" to "cache hit ratio 0.94", "WARN" to "slow request: GET /api/library took 1480ms",
        "INFO" to "connection accepted from 10.0.0.12", "ERROR" to "upstream connection refused, retrying in 5s",
        "INFO" to "scheduled job finished in 312ms", "DEBUG" to "gc pause 4ms", "INFO" to "listening on :8080",
    )

    fun line(source: String, random: Random, secondsAgo: Int): String {
        val (level, msg) = messages[random.nextInt(messages.size)]
        val time = java.time.Instant.now().minusSeconds(secondsAgo.toLong() * 7).truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
        return "$time $level $msg"
    }
}

/** A fake shell: it types back what you type and answers a few commands. It never runs what is typed. */
class DemoShell(private val world: DemoWorld, private val container: String?) : ShellSession {
    private val out = Channel<ByteArray>(Channel.UNLIMITED)
    private val ended = CompletableDeferred<SessionEnd>()
    private val line = StringBuilder()
    private val prompt = if (container != null) "root@${container.take(12)}:/# " else "demo@${world.hostname}:~\$ "

    override val output: Flow<ByteArray> = out.receiveAsFlow()

    init {
        emit("Welcome to ${world.prettyOs} (demo)\r\n\r\nThis is a made-up shell: it prints canned answers and never runs what you type.\r\nTry: help\r\n\r\n$prompt")
    }

    private fun emit(text: String) { out.trySend(text.toByteArray()) }

    override suspend fun write(bytes: ByteArray) {
        for (ch in String(bytes)) {
            when {
                ch == '\r' || ch == '\n' -> { emit("\r\n"); run(line.toString().trim()); line.clear(); if (!ended.isCompleted) emit(prompt) }
                ch == '\u007f' || ch == '\b' -> if (line.isNotEmpty()) { line.deleteCharAt(line.length - 1); emit("\b \b") }
                ch == '\u0003' -> { line.clear(); emit("^C\r\n$prompt") }
                ch.code >= 32 -> { line.append(ch); emit(ch.toString()) }
            }
        }
    }

    private fun run(command: String) {
        when {
            command.isEmpty() -> {}
            command == "help" -> emit("help  whoami  hostname  uname  uptime  ls  pwd  date  docker ps  echo ...  clear  exit\r\n")
            command == "whoami" -> emit("${if (container != null) "root" else "demo"}\r\n")
            command == "hostname" -> emit("${world.hostname}\r\n")
            command.startsWith("uname") -> emit("Linux ${world.hostname} 6.8.0-146-generic x86_64 GNU/Linux\r\n")
            command == "uptime" -> emit(" 09:41:12 up 3 days, 11:02,  1 user,  load average: 0.42, 0.40, 0.31\r\n")
            command == "ls" -> emit("compose.yaml  data  backups\r\n")
            command == "pwd" -> emit("/home/demo\r\n")
            command == "date" -> emit("${java.util.Date()}\r\n")
            command == "docker ps" -> emit(world.containers.filter { it.state == "running" }.joinToString("") { "${it.id}  ${it.name}  ${it.status()}\r\n" })
            command.startsWith("echo ") -> emit(command.removePrefix("echo ") + "\r\n")
            command == "clear" -> emit("\u001B[2J\u001B[H")
            command == "exit" || command == "logout" -> { emit("logout\r\n"); out.close(); ended.complete(SessionEnd.RemoteExit(0)) }
            else -> emit("demo: $command: command not found (this shell only knows a few commands; try help)\r\n")
        }
    }

    private fun DemoContainer.status() = if (state == "running") "Up" else state

    override suspend fun resize(cols: Int, rows: Int) {}
    override suspend fun awaitEnd(): SessionEnd = ended.await()
    override suspend fun close() { out.close(); if (!ended.isCompleted) ended.complete(SessionEnd.ClosedByUser) }
}
