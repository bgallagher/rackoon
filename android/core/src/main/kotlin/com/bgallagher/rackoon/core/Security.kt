package com.bgallagher.rackoon.core

import com.bgallagher.rackoon.core.SecurityFinding.Severity as Sev
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

// The Security screen's checks (docs/security-plan.md), mirroring Security.swift: one read-only command (spec `security`)
// reads hardening facts as the ssh user, SecurityParser turns them into a SecuritySnapshot and SecurityRules.evaluate into
// findings. Nothing here changes a server; a check that could not be read is UNKNOWN, never a pass. Titles and advice are
// data in spec/security-checks.json (bundled as a resource, no Kotlin copy).

@Serializable
enum class SecurityScope {
    /** 0.0.0.0, :: or *: every interface. */
    @SerialName("all") ALL,
    @SerialName("public") PUBLIC,
    /** 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7, fe80::/10. */
    @SerialName("lan") LAN,
    /** 100.64.0.0/10, fd7a:115c:a1e0::/48. */
    @SerialName("tailscale") TAILSCALE,
    @SerialName("loopback") LOOPBACK;

    /** Reachable from other machines. */
    val isExposed: Boolean get() = this == ALL || this == PUBLIC
}

@Serializable
data class SecuritySnapshot(
    val uid: Int? = null,
    val os: OS,
    val sshd: SSHD,
    @SerialName("tailscaleSSH") val tailscaleSSH: Boolean? = null,
    val firewall: Firewall,
    val guards: Map<String, String>,
    val listeners: List<Listener>,
    val docker: DockerExposure,
    val unattended: Unattended,
    val rootAccounts: List<String>,
    /** Accounts whose /etc/shadow password field is empty; null when it was not read (it needs root: Check Deeper). */
    val emptyPasswordAccounts: List<String>? = null,
    val aslr: Int? = null,
    val ntpSynchronized: Boolean? = null,
) {
    val isRoot: Boolean get() = uid == 0

    @Serializable
    data class OS(val id: String, val like: String, val version: String) {
        val isDebianLike: Boolean get() = id == "debian" || id == "ubuntu" || like.split(" ").contains("debian")
    }

    @Serializable
    enum class Source {
        /** `sshd -T`: the settings sshd really uses (needs root). */
        @SerialName("effective") EFFECTIVE,
        /** The config files, read in sshd's first-value-wins order. */
        @SerialName("files") FILES,
        @SerialName("none") NONE,
    }

    @Serializable
    data class SSHD(
        val installed: Boolean,
        val active: Boolean,
        val source: Source,
        val settings: Map<String, String> = emptyMap(),
        val origin: Map<String, String> = emptyMap(),
        val unreadable: List<String> = emptyList(),
        val uncertain: List<String> = emptyList(),
    )

    @Serializable
    data class Firewall(val ufwEnabled: Boolean? = null, val services: Map<String, String> = emptyMap())

    @Serializable
    data class Listener(val proto: String, val address: String, val port: Int, val scope: SecurityScope)

    @Serializable
    data class Published(val container: String, val address: String, val port: String, val proto: String, val scope: SecurityScope)

    @Serializable
    data class Container(
        val name: String,
        val privileged: Boolean,
        val hostNetwork: Boolean,
        @SerialName("hostPID") val hostPID: Boolean,
        val dockerSocket: Boolean,
        val hostRoot: Boolean,
    )

    @Serializable
    data class DockerExposure(
        val installed: Boolean = false,
        val problem: String? = null,
        val published: List<Published> = emptyList(),
        val containers: List<Container> = emptyList(),
    )

    @Serializable
    data class Unattended(val installed: Boolean = false, val enabled: Boolean? = null)
}

object SecurityParser {
    val sshdKeywords: Set<String> = setOf(
        "port", "permitrootlogin", "passwordauthentication", "kbdinteractiveauthentication", "challengeresponseauthentication",
        "permitemptypasswords", "maxauthtries", "x11forwarding",
    )

    private val intPattern = Regex("[+-]?[0-9]+")
    private fun int(text: String?): Int? = text?.takeIf { intPattern.matches(it) }?.toIntOrNull()
    private fun String.trimBlanks(): String = trim(' ', '\t')

    fun parse(output: String): SecuritySnapshot {
        val sections = sections(output)
        fun lines(name: String): List<String> = sections[name] ?: emptyList()
        val os = keyValues(lines("os"))
        val sshdState = keyValues(lines("sshd"))

        var tailscale: Boolean? = null
        lines("tailscale_ssh").firstOrNull()?.let { run ->
            val colon = run.lastIndexOf(':')
            if (colon >= 0) tailscale = run.substring(colon + 1).trimBlanks() == "true"
        }
        val firewall = keyValues(lines("firewall")).toMutableMap()
        val enabled = firewall.remove("ENABLED")

        val unattendedLines = lines("unattended")
        val prefix = "APT::Periodic::Unattended-Upgrade "
        val periodic = unattendedLines.firstOrNull { it.startsWith(prefix) }
        val unattendedEnabled = periodic?.let { int(it.removePrefix(prefix).trim('"', ';', ' '))?.let { n -> n > 0 } }

        return SecuritySnapshot(
            uid = lines("uid").firstOrNull()?.let { int(it.trimBlanks()) },
            os = SecuritySnapshot.OS(os["id"] ?: "", os["like"] ?: "", os["version"] ?: ""),
            sshd = sshd(
                installed = sshdState["installed"] == "yes", active = (int(sshdState["active"]) ?: 0) > 0,
                effective = lines("sshd_effective"), files = lines("sshd_files"),
            ),
            tailscaleSSH = tailscale,
            firewall = SecuritySnapshot.Firewall(enabled?.let { it.lowercase() == "yes" }, firewall),
            guards = keyValues(lines("guards")),
            listeners = listeners(lines("listen")),
            docker = docker(lines("docker"), lines("docker_inspect")),
            unattended = SecuritySnapshot.Unattended(
                installed = unattendedLines.any { it.startsWith("package=") && it.endsWith(" installed") },
                enabled = unattendedEnabled,
            ),
            rootAccounts = lines("uid0").map { it.trimBlanks() }.filter { it.isNotEmpty() },
            emptyPasswordAccounts = lines("shadow_empty").takeIf { it.firstOrNull() == "checked" }
                ?.drop(1)?.map { it.trimBlanks() }?.filter { it.isNotEmpty() },
            aslr = lines("aslr").firstOrNull()?.let { int(it.trimBlanks()) },
            ntpSynchronized = lines("ntp").firstOrNull()?.let {
                when (it.trimBlanks()) { "yes" -> true; "no" -> false; else -> null }
            },
        )
    }

    /** `##name` sections; lines before the first marker and empty lines are dropped, a repeated header continues. */
    fun sections(output: String): Map<String, List<String>> {
        val out = LinkedHashMap<String, MutableList<String>>()
        var current: String? = null
        for (raw in output.split("\n")) {
            val line = raw.trim('\r')
            if (line.startsWith("##")) {
                current = line.substring(2)
                out.getOrPut(current) { mutableListOf() }
            } else if (current != null && line.isNotEmpty()) {
                out.getValue(current).add(line)
            }
        }
        return out
    }

    private fun keyValues(lines: List<String>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (line in lines) {
            val eq = line.indexOf('=')
            if (eq >= 0) out[line.substring(0, eq).trimBlanks()] = line.substring(eq + 1).trimBlanks()
        }
        return out
    }

    // sshd

    private class ConfigFile(val path: String, val readable: Boolean, val lines: MutableList<String> = mutableListOf())

    fun sshd(installed: Boolean, active: Boolean, effective: List<String>, files: List<String>): SecuritySnapshot.SSHD {
        val fromSshdT = effective.mapNotNull(::keywordLine)
        if (fromSshdT.isNotEmpty()) {
            val settings = LinkedHashMap<String, String>()
            for ((k, v) in fromSshdT) settings.putIfAbsent(k, v)
            return SecuritySnapshot.SSHD(installed, active, SecuritySnapshot.Source.EFFECTIVE, settings)
        }
        val parsed = mutableListOf<ConfigFile>()
        for (line in files) {
            when {
                line.startsWith("#file ") -> parsed.add(ConfigFile(line.substring(6), true))
                line.startsWith("#unreadable ") -> parsed.add(ConfigFile(line.substring(12), false))
                parsed.isNotEmpty() -> parsed.last().lines.add(line)
            }
        }
        val unreadable = parsed.filter { !it.readable }.map { it.path }
        if (parsed.isEmpty()) return SecuritySnapshot.SSHD(installed, active, SecuritySnapshot.Source.NONE, unreadable = unreadable)

        // sshd reads the main file top to bottom, splicing each Include in where it appears; the first value of a keyword
        // wins, and lines after a Match apply only to some connections, so they are skipped (to the end of that file).
        val settings = LinkedHashMap<String, String>()
        val origin = LinkedHashMap<String, String>()
        val uncertain = mutableSetOf<String>()
        val seen = mutableSetOf(parsed.first().path)
        fun walk(file: ConfigFile, depth: Int) {
            if (depth >= 4) return
            if (!file.readable) {
                uncertain.addAll(sshdKeywords - settings.keys)
                return
            }
            for (line in file.lines) {
                val (key, value) = keywordLine(line) ?: continue
                if (key == "match") return
                if (key == "include") {
                    for (pattern in value.split(" ").filter { it.isNotEmpty() }) {
                        val full = if (pattern.startsWith("/")) pattern else "/etc/ssh/$pattern"
                        for (included in parsed.drop(1)) {
                            if (included.path !in seen && globMatches(full, included.path)) {
                                seen.add(included.path)
                                walk(included, depth + 1)
                            }
                        }
                    }
                    continue
                }
                if (key !in settings) {
                    settings[key] = value
                    origin[key] = file.path
                }
            }
        }
        walk(parsed.first(), 0)
        return SecuritySnapshot.SSHD(
            installed, active, SecuritySnapshot.Source.FILES, settings, origin, unreadable,
            (uncertain - setOf("port", "challengeresponseauthentication")).sorted(),
        )
    }

    /** `Keyword value` or `Keyword=value`, keyword lower-cased; comments and other keywords give null. */
    fun keywordLine(line: String): Pair<String, String>? {
        val trimmed = line.trimBlanks()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) return null
        val split = trimmed.indexOfFirst { it == ' ' || it == '\t' || it == '=' }
        if (split < 0) return null
        val key = trimmed.substring(0, split).lowercase()
        if (key !in sshdKeywords && key != "include" && key != "match") return null
        val value = trimmed.substring(split + 1).trim(' ', '\t', '=')
        return key to (if (key == "include" || key == "match") value else value.lowercase())
    }

    /** Shell-style `*` and `?` against a whole path; `*` never crosses `/`. */
    fun globMatches(pattern: String, path: String): Boolean {
        val memo = HashMap<Long, Boolean>()
        fun match(i: Int, j: Int): Boolean {
            val k = i.toLong() * (path.length + 1) + j
            memo[k]?.let { return it }
            val r = when {
                i == pattern.length -> j == path.length
                pattern[i] == '*' -> match(i + 1, j) || (j < path.length && path[j] != '/' && match(i, j + 1))
                else -> j < path.length && (pattern[i] == '?' || pattern[i] == path[j]) && match(i + 1, j + 1)
            }
            memo[k] = r
            return r
        }
        return match(0, 0)
    }

    // listeners

    /** `ss -H -tuln` lines: netid, state, queues, local address:port, peer. */
    fun listeners(lines: List<String>): List<SecuritySnapshot.Listener> {
        val out = mutableListOf<SecuritySnapshot.Listener>()
        for (line in lines) {
            val cols = line.split(' ', '\t').filter { it.isNotEmpty() }
            if (cols.size < 5) continue
            val (address, port) = hostPort(cols[4]) ?: continue
            val number = int(port) ?: continue
            val listener = SecuritySnapshot.Listener(cols[0], address, number, scope(address))
            if (listener !in out) out.add(listener)
        }
        return out.sortedWith(compareBy({ it.port }, { it.proto }, { it.scope.ordinal }, { it.address }))
    }

    /** Splits `addr:port`, `[v6]:port` or `*:port`; drops a `%interface` suffix and IPv4-mapped prefixes. */
    fun hostPort(text: String): Pair<String, String>? {
        val colon = text.lastIndexOf(':')
        if (colon < 0) return null
        var host = text.substring(0, colon)
        val port = text.substring(colon + 1)
        if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length - 1)
        host.indexOf('%').takeIf { it >= 0 }?.let { host = host.substring(0, it) }
        if (host.lowercase().startsWith("::ffff:") && host.contains(".")) host = host.substring(7)
        if (host.isEmpty()) host = "::"   // docker's old ":::8080"
        return host to port
    }

    fun scope(address: String): SecurityScope {
        val a = address.lowercase()
        if (a == "*" || a == "0.0.0.0" || a == "::") return SecurityScope.ALL
        if (a == "::1" || a.startsWith("127.") || a == "localhost") return SecurityScope.LOOPBACK
        val v4 = a.split(".").filter { it.isNotEmpty() }.mapNotNull { int(it) }
        if (v4.size == 4) {
            val (x, y) = v4[0] to v4[1]
            return when {
                x == 100 && y in 64..127 -> SecurityScope.TAILSCALE
                x == 10 || (x == 192 && y == 168) || (x == 172 && y in 16..31) || (x == 169 && y == 254) -> SecurityScope.LAN
                else -> SecurityScope.PUBLIC
            }
        }
        if (a.startsWith("fd7a:115c:a1e0:")) return SecurityScope.TAILSCALE
        if (listOf("fe8", "fe9", "fea", "feb", "fc", "fd").any { a.startsWith(it) }) return SecurityScope.LAN
        return SecurityScope.PUBLIC
    }

    // docker

    fun docker(lines: List<String>, inspect: List<String>): SecuritySnapshot.DockerExposure {
        if (lines.firstOrNull() != "installed=yes") return SecuritySnapshot.DockerExposure()
        val published = mutableListOf<SecuritySnapshot.Published>()
        val problem = mutableListOf<String>()
        for (line in lines.drop(1)) {
            val tab = line.indexOf('\t')
            if (tab < 0) { problem.add(line); continue }
            val name = line.substring(0, tab)
            for (entry in line.substring(tab + 1).split(",")) {
                val item = entry.trimBlanks()
                val arrow = item.indexOf("->")
                if (arrow < 0) continue   // exposed but not published
                val (address, port) = hostPort(item.substring(0, arrow)) ?: continue
                val proto = item.split("/").last()
                val p = SecuritySnapshot.Published(name, address, port, proto, scope(address))
                if (p !in published) published.add(p)
            }
        }
        val containers = inspect.mapNotNull { line ->
            val f = line.split("|")
            if (f.size < 5) return@mapNotNull null
            val mounts = f[4].split(";").filter { it.isNotEmpty() }
            SecuritySnapshot.Container(
                name = f[0].removePrefix("/"),
                privileged = f[1] == "true", hostNetwork = f[2] == "host", hostPID = f[3] == "host",
                dockerSocket = mounts.any { it == "/var/run/docker.sock" || it == "/run/docker.sock" },
                hostRoot = "/" in mounts,
            )
        }.sortedBy { it.name }
        return SecuritySnapshot.DockerExposure(true, problem.takeIf { it.isNotEmpty() }?.joinToString(" "), published, containers)
    }
}

// Checks and findings

@Serializable
data class SecurityCheck(val id: String, val group: String, val title: String, val why: String, val advice: String)

object SecurityChecks {
    private val doc: JsonObject by lazy {
        val text = SecurityChecks::class.java.getResourceAsStream("/spec/security-checks.json")?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("spec/security-checks.json is missing from the module resources")
        Json.parseToJsonElement(text) as JsonObject
    }

    /** The catalog, from spec/security-checks.json. */
    val all: List<SecurityCheck> by lazy {
        val json = Json { ignoreUnknownKeys = true }
        (doc["checks"] as JsonArray).map { json.decodeFromJsonElement(SecurityCheck.serializer(), it) }
    }

    /** Group id -> title, in display order. */
    val groups: List<Pair<String, String>> by lazy {
        (doc["groups"] as JsonArray).map { val o = it as JsonObject; o["id"]!!.jsonPrimitive.content to o["title"]!!.jsonPrimitive.content }
    }

    fun check(id: String): SecurityCheck? = all.firstOrNull { it.id == id }
}

@Serializable
data class SecurityFinding(
    /** The check's id, plus `:<subject>` for one finding per item (a port, a container). */
    val id: String,
    val check: String,
    val severity: Severity,
    val summary: String,
    val evidence: String? = null,
) {
    @Serializable
    enum class Severity {
        @SerialName("critical") CRITICAL,
        @SerialName("warning") WARNING,
        @SerialName("info") INFO,
        @SerialName("unknown") UNKNOWN,
        @SerialName("pass") PASS;

        val raw: String get() = name.lowercase()
    }
}

/** What the Overview poll already knows, so the Security command does not run apt again. */
data class SecurityContext(val pendingSecurityUpdates: Int? = null, val rebootRequired: Boolean? = null)

object SecurityRules {
    val sensitivePorts: Map<Int, String> = mapOf(
        3306 to "MySQL/MariaDB", 5432 to "PostgreSQL", 6379 to "Redis", 27017 to "MongoDB", 9200 to "Elasticsearch",
        11211 to "Memcached", 5984 to "CouchDB", 8086 to "InfluxDB",
    )

    val socketTools = listOf(
        "portainer", "watchtower", "traefik", "homepage", "dozzle", "dockge", "diun", "autoheal", "beszel", "uptime-kuma",
        "socket-proxy", "cadvisor", "netdata",
    )

    /** sshd's built-in defaults for the keywords Rackoon checks (OpenSSH 8.7 and later). */
    val defaults: Map<String, String> = mapOf(
        "port" to "22", "permitrootlogin" to "prohibit-password", "passwordauthentication" to "yes",
        "kbdinteractiveauthentication" to "yes", "permitemptypasswords" to "no", "maxauthtries" to "6", "x11forwarding" to "no",
    )

    private class Setting(val value: String, val isDefault: Boolean, val certain: Boolean, val evidence: String)

    fun ufwOn(s: SecuritySnapshot): Boolean = s.firewall.services["ufw"] == "active" && s.firewall.ufwEnabled != false

    fun evaluate(s: SecuritySnapshot, context: SecurityContext = SecurityContext()): List<SecurityFinding> {
        val out = mutableListOf<SecurityFinding>()
        fun add(check: String, severity: SecurityFinding.Severity, summary: String, evidence: String? = null, subject: String? = null) {
            out.add(SecurityFinding(subject?.let { "$check:$it" } ?: check, check, severity, summary, evidence))
        }

        // SSH
        val sshd = s.sshd
        val sshOn = sshd.installed && sshd.active
        val passwordsOn: Boolean?
        if (!sshd.installed) {
            add("ssh.server", Sev.INFO, "No OpenSSH server is installed.")
            passwordsOn = false
        } else if (sshd.source == SecuritySnapshot.Source.NONE) {
            add("ssh.server", Sev.UNKNOWN, "Rackoon could not read sshd's settings.",
                evidence = if (sshd.unreadable.isEmpty()) null else "Unreadable: " + sshd.unreadable.joinToString(", "))
            passwordsOn = null
        } else {
            add("ssh.server", if (sshOn) Sev.PASS else Sev.INFO,
                if (sshOn) "OpenSSH is running." else "OpenSSH is installed but not running.",
                evidence = if (sshd.source == SecuritySnapshot.Source.EFFECTIVE) "From sshd -T (the settings in use)." else "From the config files (sshd -T needs root).")
            fun setting(key: String): Setting {
                val certain = key !in sshd.uncertain
                sshd.settings[key]?.let { value ->
                    val from = sshd.origin[key]?.let { " in $it" } ?: ""
                    return Setting(value, false, certain, "$key $value$from")
                }
                val value = defaults[key] ?: ""
                return Setting(value, true, certain, "$key not set, so sshd uses its default: $value")
            }
            fun unsure(e: String) = "$e. A file Rackoon cannot read (${sshd.unreadable.joinToString(", ")}) may set it first."

            val root = setting("permitrootlogin")
            when {
                !root.certain -> add("ssh.root_login", Sev.UNKNOWN, "Root login could not be read for certain.", evidence = unsure(root.evidence))
                root.value == "yes" -> add("ssh.root_login", Sev.CRITICAL, "Root can log in with a password.", evidence = root.evidence)
                else -> add("ssh.root_login", Sev.PASS, if (root.value == "no") "Root cannot log in over SSH." else "Root can log in with a key only.",
                    evidence = root.evidence)
            }

            val password = setting("passwordauthentication")
            val keyboard = setting("kbdinteractiveauthentication")
            val challenge = sshd.settings["challengeresponseauthentication"]
            // KbdInteractiveAuthentication's old name, ChallengeResponseAuthentication, counts when the new one is not set.
            val keyboardOn = if (keyboard.isDefault) (challenge?.let { it == "yes" } ?: (keyboard.value == "yes")) else keyboard.value == "yes"
            val passwordEvidence = "${password.evidence}; ${keyboard.evidence}"
            val pwSure = password.certain && password.value == "yes"
            val kbSure = keyboard.certain && keyboardOn
            if (pwSure || kbSure) {
                val which = listOfNotNull(if (pwSure) "passwords" else null, if (kbSure) "keyboard-interactive logins" else null).joinToString(" and ")
                add("ssh.password_auth", Sev.WARNING, "SSH accepts $which.", evidence = passwordEvidence)
                passwordsOn = true
            } else if (!password.certain || !keyboard.certain) {
                add("ssh.password_auth", Sev.UNKNOWN, "Password logins could not be read for certain.", evidence = unsure(passwordEvidence))
                passwordsOn = null
            } else {
                add("ssh.password_auth", Sev.PASS, "SSH accepts keys only.", evidence = passwordEvidence)
                passwordsOn = false
            }

            val empty = setting("permitemptypasswords")
            when {
                !empty.certain -> add("ssh.empty_passwords", Sev.UNKNOWN, "Empty-password logins could not be read for certain.", evidence = unsure(empty.evidence))
                empty.value == "yes" -> add("ssh.empty_passwords", Sev.CRITICAL, "Accounts with an empty password can log in.", evidence = empty.evidence)
                else -> add("ssh.empty_passwords", Sev.PASS, "Empty passwords are refused.", evidence = empty.evidence)
            }

            val tries = setting("maxauthtries")
            val n = tries.value.toIntOrNull()
            if (n != null && n > 6) add("ssh.max_auth_tries", Sev.INFO, "Each connection may try $n logins.", evidence = tries.evidence)
            else add("ssh.max_auth_tries", Sev.PASS, "At most ${tries.value} login attempts per connection.", evidence = tries.evidence)

            val x11 = setting("x11forwarding")
            add("ssh.x11_forwarding", if (x11.value == "yes") Sev.INFO else Sev.PASS,
                if (x11.value == "yes") "X11 forwarding is on." else "X11 forwarding is off.", evidence = x11.evidence)
        }
        if (s.tailscaleSSH == true) add("ssh.tailscale", Sev.INFO, "Tailscale SSH is on: tailnet logins follow your tailnet's SSH policy.")

        // Firewall and exposure
        fun active(unit: String) = s.firewall.services[unit] == "active"
        val ufwOn = ufwOn(s)
        when {
            ufwOn -> add("exposure.firewall", Sev.PASS, "ufw is on.")
            active("firewalld") -> add("exposure.firewall", Sev.PASS, "firewalld is on.")
            active("nftables") -> add("exposure.firewall", Sev.INFO, "nftables rules are loaded, but reading them needs root.",
                evidence = "Debian's default nftables.conf allows everything; check it with sudo nft list ruleset.")
            s.firewall.services.values.all { it.isEmpty() } -> add("exposure.firewall", Sev.UNKNOWN, "Rackoon could not ask systemd about firewalls.")
            else -> add("exposure.firewall", Sev.WARNING, "No firewall is running.",
                evidence = s.firewall.services.toSortedMap().entries.joinToString(", ") { "${it.key}: ${it.value}" })
        }

        val exposed = s.listeners.filter { it.scope.isExposed }
        val exposedPorts = exposed.map { "${it.port}/${it.proto}" }.toSet()
            .sortedWith(compareBy({ p -> p.takeWhile { it.isDigit() }.toIntOrNull() ?: 0 }, { it }))
        when {
            s.listeners.isEmpty() -> add("exposure.listening", Sev.UNKNOWN, "Rackoon could not list listening sockets.")
            exposedPorts.isEmpty() -> add("exposure.listening", Sev.PASS, "Nothing listens on every interface.")
            else -> add("exposure.listening", Sev.INFO,
                "${exposedPorts.size} port${if (exposedPorts.size == 1) "" else "s"} listen on every interface.",
                evidence = exposedPorts.joinToString(", "))
        }
        val sensitiveSeen = mutableSetOf<Int>()
        for (l in exposed) {
            if (l.proto != "tcp") continue
            val name = sensitivePorts[l.port] ?: continue
            if (!sensitiveSeen.add(l.port)) continue
            add("exposure.sensitive_port", Sev.WARNING, "$name (port ${l.port}) listens on every interface.",
                evidence = "${l.proto} ${l.address}:${l.port}", subject = "${l.port}")
        }

        val dockerExposed = s.docker.published.filter { it.scope.isExposed }
        if (ufwOn && dockerExposed.isNotEmpty()) {
            val list = dockerExposed.map { "${it.port}/${it.proto} (${it.container})" }.toSet().sorted()
            add("exposure.docker_bypass", Sev.WARNING,
                "Docker publishes ${list.size} port${if (list.size == 1) "" else "s"} on every interface, past ufw.",
                evidence = list.joinToString(", "))
        }

        // Brute-force protection
        val guarding = listOf("fail2ban", "crowdsec", "sshguard").filter { s.guards[it] == "active" }
        when {
            guarding.isNotEmpty() -> add("brute_force.guard", Sev.PASS, "${guarding.joinToString(" and ")} is running.")
            !sshOn -> add("brute_force.guard", Sev.PASS, "No SSH server to protect.")
            s.guards.values.all { it.isEmpty() } -> add("brute_force.guard", Sev.UNKNOWN, "Rackoon could not ask systemd about fail2ban, CrowdSec or sshguard.")
            passwordsOn == false -> add("brute_force.guard", Sev.INFO, "No fail2ban, CrowdSec or sshguard (less important with password logins off).")
            else -> add("brute_force.guard", Sev.WARNING, "No fail2ban, CrowdSec or sshguard, and SSH may accept passwords.")
        }

        // Updates
        if (s.os.isDebianLike) {
            val pending = context.pendingSecurityUpdates
            when {
                pending != null && pending > 0 -> add("updates.security_pending", Sev.WARNING,
                    "$pending security update${if (pending == 1) " is" else "s are"} waiting to be installed.")
                pending != null -> add("updates.security_pending", Sev.PASS, "No security updates waiting.")
                else -> add("updates.security_pending", Sev.UNKNOWN, "The update count is not known yet.")
            }
            when {
                s.unattended.installed && s.unattended.enabled == true ->
                    add("updates.automatic", Sev.PASS, "unattended-upgrades installs security updates automatically.")
                s.unattended.installed -> add("updates.automatic", Sev.INFO, "unattended-upgrades is installed but not switched on.",
                    evidence = "APT::Periodic::Unattended-Upgrade is ${if (s.unattended.enabled == false) "0" else "not set"}.")
                else -> add("updates.automatic", Sev.INFO, "Security updates are not installed automatically.",
                    evidence = "The unattended-upgrades package is not installed.")
            }
        }
        when (context.rebootRequired) {
            true -> add("updates.reboot", Sev.WARNING, "The server asks for a reboot to finish updates.")
            false -> add("updates.reboot", Sev.PASS, "No reboot pending.")
            null -> {}
        }

        // Accounts
        val extra = s.rootAccounts.filter { it != "root" }
        when {
            s.rootAccounts.isEmpty() -> add("accounts.extra_root", Sev.UNKNOWN, "Rackoon could not read /etc/passwd.")
            extra.isEmpty() -> add("accounts.extra_root", Sev.PASS, "Only root has user id 0.")
            else -> add("accounts.extra_root", Sev.CRITICAL, "Other accounts have user id 0: ${extra.joinToString(", ")}.",
                evidence = "UID 0 in /etc/passwd: " + s.rootAccounts.joinToString(", "))
        }

        val empty = s.emptyPasswordAccounts
        when {
            empty == null -> add("accounts.empty_password", Sev.UNKNOWN, "Reading /etc/shadow needs root: use Check Deeper with sudo.")
            empty.isEmpty() -> add("accounts.empty_password", Sev.PASS, "No account has an empty password.")
            else -> add("accounts.empty_password", Sev.CRITICAL, "Accounts with an empty password: ${empty.joinToString(", ")}.",
                evidence = "Empty password field in /etc/shadow: " + empty.joinToString(", "))
        }

        // Docker
        fun api(port: Int) = s.listeners.firstOrNull { it.port == port && it.proto == "tcp" && it.scope != SecurityScope.LOOPBACK }
        val plain = api(2375)
        val tls = api(2376)
        if (plain != null) add("docker.tcp_api", Sev.CRITICAL, "Docker's API answers without TLS on port 2375.", evidence = "tcp ${plain.address}:2375")
        else if (tls != null) add("docker.tcp_api", Sev.INFO, "Docker's API listens on port 2376 (TLS); make sure it requires client certificates.",
            evidence = "tcp ${tls.address}:2376")
        if (s.docker.installed) {
            s.docker.problem?.let { add("docker.unchecked", Sev.UNKNOWN, "Docker would not list containers for this user.", evidence = it) }
            for (c in s.docker.containers) {
                val reasons = listOfNotNull(
                    "privileged".takeIf { c.privileged }, "host network".takeIf { c.hostNetwork },
                    "host PID namespace".takeIf { c.hostPID }, "Docker socket mounted".takeIf { c.dockerSocket },
                    "host / mounted".takeIf { c.hostRoot },
                )
                if (reasons.isEmpty()) continue
                val expected = c.dockerSocket && reasons.size == 1 && socketTools.any { c.name.lowercase().contains(it) }
                add("docker.container", if (expected) Sev.INFO else Sev.WARNING,
                    "${c.name}: ${reasons.joinToString(", ")}${if (expected) " (expected for this tool)" else ""}.", subject = c.name)
            }
        }

        // Kernel and time
        when (val aslr = s.aslr) {
            2 -> add("system.aslr", Sev.PASS, "Full address space randomisation.")
            null -> add("system.aslr", Sev.UNKNOWN, "Rackoon could not read the ASLR setting.")
            else -> add("system.aslr", Sev.WARNING, "Address space randomisation is ${if (aslr == 0) "off" else "partial"} ($aslr).",
                evidence = "/proc/sys/kernel/randomize_va_space = $aslr")
        }
        when (s.ntpSynchronized) {
            true -> add("system.time_sync", Sev.PASS, "The clock is synchronised.")
            false -> add("system.time_sync", Sev.INFO, "The clock is not synchronised.", evidence = "timedatectl: NTPSynchronized=no")
            null -> add("system.time_sync", Sev.UNKNOWN, "Rackoon could not ask timedatectl.")
        }
        return out
    }

    fun counts(findings: List<SecurityFinding>): Map<SecurityFinding.Severity, Int> = findings.groupingBy { it.severity }.eachCount()
}

/** Runs the read-only `security` command. */
object SecuritySession {
    val command: String get() = SpecCommands.script("security")

    suspend fun read(transport: SSHTransport): SecuritySnapshot {
        val result = transport.run(command, 20_000)
        if (result.exitCode != 0) throw SessionError.CommandFailed(result.exitCode, result.stderr.trim())
        return SecurityParser.parse(result.stdout)
    }
}

/** One port as the Security screen shows it: IPv4 and IPv6 merged, the widest scope, who published it and why it is worth a look. */
data class ExposedPort(
    val port: Int,
    val proto: String,
    val scope: SecurityScope,
    val addresses: List<String>,
    val containers: List<String>,
    val service: String?,
    val flags: List<String>,
) {
    val id: String get() = "$port/$proto"
    val isExposed: Boolean get() = scope.isExposed
}

object SecurityExposure {
    val knownPorts: Map<Int, String> = mapOf(
        22 to "SSH", 53 to "DNS", 80 to "HTTP", 443 to "HTTPS", 25 to "SMTP", 111 to "rpcbind", 139 to "SMB", 445 to "SMB",
        631 to "Printing (CUPS)", 2049 to "NFS", 2375 to "Docker API", 2376 to "Docker API (TLS)", 3389 to "Remote Desktop",
        5900 to "VNC", 8080 to "HTTP (alt)", 8443 to "HTTPS (alt)", 41641 to "Tailscale", 51820 to "WireGuard", 32400 to "Plex",
    ) + SecurityRules.sensitivePorts

    fun ports(s: SecuritySnapshot, ufwOn: Boolean): List<ExposedPort> {
        val merged = LinkedHashMap<String, ExposedPort>()
        for (l in s.listeners) {
            val key = "${l.port}/${l.proto}"
            val row = merged[key] ?: ExposedPort(l.port, l.proto, l.scope, emptyList(), emptyList(), knownPorts[l.port], emptyList())
            merged[key] = row.copy(
                scope = if (l.scope.ordinal < row.scope.ordinal) l.scope else row.scope,
                addresses = if (l.address in row.addresses) row.addresses else row.addresses + l.address,
            )
        }
        for (p in s.docker.published) {
            val port = p.port.toIntOrNull() ?: continue
            val row = merged["$port/${p.proto}"] ?: continue
            merged[row.id] = row.copy(
                containers = if (p.container in row.containers) row.containers else row.containers + p.container,
                flags = if (ufwOn && p.scope.isExposed && "past ufw" !in row.flags) row.flags + "past ufw" else row.flags,
            )
        }
        for ((key, row) in merged.entries.toList()) {
            if (!row.isExposed) continue
            var flags = row.flags
            if (row.proto == "tcp" && SecurityRules.sensitivePorts.containsKey(row.port)) flags = listOf("database or cache") + flags
            if (row.proto == "tcp" && row.port == 2375) flags = listOf("no TLS") + flags
            merged[key] = row.copy(flags = flags)
        }
        return merged.values.sortedWith(compareBy({ it.scope.ordinal }, { it.port }, { it.proto }))
    }
}
