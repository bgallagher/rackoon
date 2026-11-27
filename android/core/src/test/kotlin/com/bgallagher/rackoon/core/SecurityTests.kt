package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors SecurityTests in RackoonCore (Swift). */
class SecurityTests {
    private fun fixture(name: String) = SecurityParser.parse(Spec.out("security", name))

    private fun finding(findings: List<SecurityFinding>, id: String): SecurityFinding =
        assertNotNull(findings.firstOrNull { it.id == id }, "no $id in ${findings.map { it.id }}")

    @Test fun everySecurityFixtureMatchesItsGoldenFile() {
        val names = Spec.fixtures("security")
        assertTrue(names.size >= 3)
        for (name in names) {
            val actual = Json.parseToJsonElement(Spec.json.encodeToString(SecuritySnapshot.serializer(), fixture(name)))
            assertJsonEquals(Spec.expected("security", name), actual, "security/$name")
        }
    }

    /** spec/scenarios/security-checks.json, run here whatever features.json says, so the rules are proven ahead of the screen. */
    @Test fun sharedScenarios() {
        val doc = Spec.parse("scenarios/security-checks.json").jsonObject
        for (c in doc["cases"]!!.jsonArray.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            val ctx = c["context"]!!.jsonObject
            val context = SecurityContext(
                ctx["pendingSecurityUpdates"]?.takeIf { it != JsonNull }?.jsonPrimitive?.intOrNull,
                ctx["rebootRequired"]?.takeIf { it != JsonNull }?.jsonPrimitive?.booleanOrNull,
            )
            val got = LinkedHashMap<String, String>()
            for (f in SecurityRules.evaluate(fixture(c["fixture"]!!.jsonPrimitive.content), context)) got.putIfAbsent(f.id, f.severity.raw)
            for ((id, severity) in c["expect"]!!.jsonObject) assertEquals(severity.jsonPrimitive.content, got[id], "$name: $id")
            for (id in c["absent"]?.jsonArray ?: emptyList()) assertNull(got[id.jsonPrimitive.content], "$name: ${id.jsonPrimitive.content} should not appear")
        }
    }

    @Test fun checksComeFromTheSpecCatalog() {
        val doc = Spec.parse("security-checks.json").jsonObject
        assertEquals(doc["checks"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content }, SecurityChecks.all.map { it.id })
        assertEquals(listOf("ssh", "exposure", "brute_force", "updates", "accounts", "docker", "system"), SecurityChecks.groups.map { it.first })
    }

    @Test fun commandComesFromTheSpec() {
        val spec = Spec.parse("commands.json").jsonObject["commands"]!!.jsonArray.map { it.jsonObject }
            .first { it["id"]!!.jsonPrimitive.content == "security" }
        assertEquals(spec["script"]!!.jsonPrimitive.content, SecuritySession.command)
    }

    @Test fun everyFindingNamesACheckInTheCatalog() {
        for (name in listOf("synthetic-ubuntu-hardened", "synthetic-ubuntu-default", "synthetic-debian-exposed")) {
            for (f in SecurityRules.evaluate(fixture(name), SecurityContext(1, true))) {
                assertNotNull(SecurityChecks.check(f.check), "$name: ${f.check}")
                assertTrue(f.id == f.check || f.id.startsWith(f.check + ":"), f.id)
            }
        }
    }

    @Test fun dropInsComeFirstWhereTheIncludeIs() {
        val s = fixture("synthetic-ubuntu-hardened")
        assertEquals(SecuritySnapshot.Source.FILES, s.sshd.source)
        assertEquals("no", s.sshd.settings["x11forwarding"])
        assertEquals("/etc/ssh/sshd_config.d/10-hardening.conf", s.sshd.origin["x11forwarding"])
        assertEquals(emptyList(), s.sshd.uncertain)
    }

    @Test fun anUnreadableDropInMakesLaterValuesUncertain() {
        val s = fixture("synthetic-ubuntu-default")
        assertEquals(listOf("/etc/ssh/sshd_config.d/50-cloud-init.conf"), s.sshd.unreadable)
        assertEquals("no", s.sshd.settings["permitrootlogin"])
        assertTrue("passwordauthentication" in s.sshd.uncertain)
        val findings = SecurityRules.evaluate(s)
        assertEquals(SecurityFinding.Severity.UNKNOWN, finding(findings, "ssh.password_auth").severity)
        assertTrue(finding(findings, "ssh.root_login").evidence!!.contains("50-cloud-init.conf"))
    }

    @Test fun rootReadsTheEffectiveSettings() {
        val s = fixture("synthetic-debian-exposed")
        assertTrue(s.isRoot)
        assertEquals(SecuritySnapshot.Source.EFFECTIVE, s.sshd.source)
        assertEquals("2222", s.sshd.settings["port"])
        assertEquals(listOf("root", "toor"), s.rootAccounts)
    }

    @Test fun listenerScopes() {
        val cases = mapOf(
            "0.0.0.0" to SecurityScope.ALL, "*" to SecurityScope.ALL, "::" to SecurityScope.ALL, "127.0.0.53" to SecurityScope.LOOPBACK,
            "::1" to SecurityScope.LOOPBACK, "100.100.40.7" to SecurityScope.TAILSCALE, "fd7a:115c:a1e0::1" to SecurityScope.TAILSCALE,
            "192.168.1.20" to SecurityScope.LAN, "172.20.0.1" to SecurityScope.LAN, "fe80::1" to SecurityScope.LAN,
            "203.0.113.24" to SecurityScope.PUBLIC, "100.63.0.1" to SecurityScope.PUBLIC,
        )
        for ((address, scope) in cases) assertEquals(scope, SecurityParser.scope(address), address)
        assertEquals("127.0.0.53" to "53", SecurityParser.hostPort("127.0.0.53%lo:53"))
        assertEquals("127.0.0.1" to "631", SecurityParser.hostPort("[::ffff:127.0.0.1]:631"))
        assertEquals("::" to "8080", SecurityParser.hostPort(":::8080"))
    }

    @Test fun includeGlobs() {
        assertTrue(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/50-cloud-init.conf"))
        assertFalse(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/x/y.conf"))
        assertFalse(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/notes.txt"))
        assertTrue(SecurityParser.globMatches("/etc/ssh/sshd_config.d/1?-a.conf", "/etc/ssh/sshd_config.d/10-a.conf"))
    }

    @Test fun dockerPublishedOnEveryInterfaceGetsPastUfw() {
        val base = fixture("synthetic-ubuntu-hardened")
        val s = base.copy(docker = base.docker.copy(published = base.docker.published +
            SecuritySnapshot.Published("web", "0.0.0.0", "8443", "tcp", SecurityScope.ALL)))
        val bypass = finding(SecurityRules.evaluate(s), "exposure.docker_bypass")
        assertEquals(SecurityFinding.Severity.WARNING, bypass.severity)
        assertEquals("8443/tcp (web)", bypass.evidence)
    }

    @Test fun countsBySeverity() {
        assertEquals(4, SecurityRules.counts(SecurityRules.evaluate(fixture("synthetic-debian-exposed")))[SecurityFinding.Severity.CRITICAL])
    }

    @Test fun ipv4AndIpv6OfOnePortAreOneRowAndTheWidestReachWins() {
        val ports = SecurityExposure.ports(fixture("synthetic-debian-exposed"), ufwOn = false)
        val mysql = ports.first { it.port == 3306 }
        assertEquals(listOf("0.0.0.0", "::"), mysql.addresses)
        assertEquals(listOf("mariadb"), mysql.containers)
        assertEquals("MySQL/MariaDB", mysql.service)
        assertEquals(listOf("database or cache"), mysql.flags)
        assertEquals(listOf("no TLS"), ports.first { it.port == 2375 }.flags)
        assertEquals(SecurityScope.ALL, ports.first().scope)
        assertEquals(9000, ports.last().port)
    }

    @Test fun dockerPortsPastUfwAreFlaggedOnlyWithUfwOn() {
        val base = fixture("synthetic-ubuntu-hardened")
        val s = base.copy(
            listeners = base.listeners + SecuritySnapshot.Listener("tcp", "0.0.0.0", 8443, SecurityScope.ALL),
            docker = base.docker.copy(published = base.docker.published + SecuritySnapshot.Published("web", "0.0.0.0", "8443", "tcp", SecurityScope.ALL)),
        )
        assertEquals(listOf("past ufw"), SecurityExposure.ports(s, ufwOn = true).first { it.port == 8443 }.flags)
        assertEquals(emptyList(), SecurityExposure.ports(s, ufwOn = false).first { it.port == 8443 }.flags)
        val tailscaleOnly = SecurityExposure.ports(s, ufwOn = true).first { it.port == 8080 }
        assertFalse(tailscaleOnly.isExposed)
        assertEquals(listOf("paperless"), tailscaleOnly.containers)
    }

    @Test fun readsThroughTheTransport() = runTest {
        val transport = FakeTransport(listOf(ok(Spec.out("security", "synthetic-ubuntu-hardened"))))
        assertEquals("ubuntu", SecuritySession.read(transport).os.id)
    }
}
