package com.bgallagher.rackoon.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.AppViewModel
import com.bgallagher.rackoon.core.ExposedPort
import com.bgallagher.rackoon.core.SecurityChecks
import com.bgallagher.rackoon.core.SecurityExposure
import com.bgallagher.rackoon.core.SecurityFinding
import com.bgallagher.rackoon.core.SecurityRules
import com.bgallagher.rackoon.core.SecurityScope
import com.bgallagher.rackoon.core.VulnerabilityFinding
import com.bgallagher.rackoon.ui.theme.Rackoon
import com.bgallagher.rackoon.ui.theme.RackoonIcons

private const val DISCLAIMER = "These checks look for a small set of common hardening problems. They are not a complete security review and can be wrong: a setting may be overridden somewhere Rackoon does not read, and new issues appear every day. Treat a clean result as \"nothing obvious found\", not \"secure\"."
private const val PRIVACY = "Sends this server's package names and versions (nothing else: no host names or addresses) from this phone to OSV.dev, a vulnerability database run by Google. Answers are kept for a day."
private const val LIMITS = "Matched by package version with OSV.dev's Debian and Ubuntu data. Kernel advisories depend on how the kernel is built and used, a backported fix can make a version look affected when it is not, and software outside apt (Docker images, binaries in /opt, pip or npm installs) is not covered."
private val SHOWN_AS_PORTS = setOf("exposure.listening", "exposure.sensitive_port", "exposure.docker_bypass")

/**
 * The Security page (More > Security, docs/security-plan.md), as on the Mac: a verdict with the disclaimer, what to fix, what
 * other networks can reach, the opt-in vulnerability lookup, what is worth knowing, what could not be checked and the passed
 * checks folded away. Advice only: nothing here changes the server.
 */
@Composable
fun SecurityScreen(vm: AppViewModel, serverId: String, serverName: String, userName: String?, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val c = Rackoon.colors
    val state by vm.security.collectAsStateWithLifecycle()
    val lookup by vm.vulnerabilityLookup.collectAsStateWithLifecycle()
    val snapshot = state.snapshot
    val findings = remember(state) { vm.securityFindings().filter { it.check !in SHOWN_AS_PORTS } }
    var showPassed by rememberSaveable { mutableStateOf(false) }
    var showLocal by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding()) {
        Row(Modifier.height(64.dp).padding(start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTap(RackoonIcons.ChevronLeft, "Back to More", c.textPrimary, onBack)
            Column(Modifier.weight(1f)) {
                Text("Security", fontSize = 18.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
                if (serverName.isNotEmpty()) Text(serverName, fontSize = 12.sp, color = c.textMuted)
            }
            if (state.loading) Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = c.accent) }
            else IconTap(RackoonIcons.Refresh, "Check again", c.textPrimary, {
                vm.loadSecurity(force = true)
                if (lookup.isOn(serverId)) vm.lookUpVulnerabilities()
            })
        }
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth().navigationBarsPadding(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            state.error?.let { item { Note(it, c.danger) } }
            if (snapshot == null) {
                if (state.error == null) item { Text("Checking…", color = c.textSecondary) }
                return@LazyColumn
            }
            val ports = SecurityExposure.ports(snapshot, SecurityRules.ufwOn(snapshot))
            val toFix = sorted(findings.filter { it.severity == SecurityFinding.Severity.CRITICAL || it.severity == SecurityFinding.Severity.WARNING })
            val open = ports.filter { it.isExposed }
            val flagged = open.count { p -> p.flags.any { it != "no TLS" } }
            item {
                val parts = listOfNotNull(
                    if (toFix.isEmpty()) null else "${toFix.size} thing${if (toFix.size == 1) "" else "s"} to fix",
                    if (flagged == 0) null else "$flagged open port${if (flagged == 1) "" else "s"} to look at",
                )
                val tint = when {
                    parts.isEmpty() -> c.ok
                    toFix.any { it.severity == SecurityFinding.Severity.CRITICAL } -> c.danger
                    else -> c.warn
                }
                RCard(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(if (parts.isEmpty()) "Nothing obvious to fix" else parts.joinToString(", "), color = tint, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                        Text(DISCLAIMER, color = c.textSecondary, fontSize = 12.sp, lineHeight = 17.sp)
                    }
                }
            }
            if (toFix.isNotEmpty()) {
                item { Heading("To fix", toFix.size) }
                items(toFix, key = { it.id }) { FindingRow(it) }
            }
            if (ports.isNotEmpty()) {
                item { Heading("Reachable from other networks", open.size) }
                items(open, key = { "open:" + it.id }) { PortRow(it) }
                val local = ports.filter { !it.isExposed }
                if (local.isNotEmpty()) {
                    item {
                        Text(
                            "${if (showLocal) "Hide" else "Show"} ${local.size} more only this server, the local network or Tailscale can reach",
                            color = c.accent, fontSize = 13.sp, modifier = Modifier.clickable { showLocal = !showLocal }.padding(vertical = 6.dp),
                        )
                    }
                    if (showLocal) items(local, key = { "local:" + it.id }) { PortRow(it) }
                }
            }
            item { Heading("Known vulnerabilities", state.vulnerabilities?.size ?: 0) }
            item { Vulnerabilities(vm, state, lookup.isOn(serverId), lookup.all, serverId in lookup.servers, serverId) }
            val info = sorted(findings.filter { it.severity == SecurityFinding.Severity.INFO })
            if (info.isNotEmpty()) {
                item { Heading("Worth knowing", info.size) }
                items(info, key = { it.id }) { FindingRow(it) }
            }
            val unknown = sorted(findings.filter { it.severity == SecurityFinding.Severity.UNKNOWN })
            if (unknown.isNotEmpty()) {
                item {
                    Heading("Could not check", unknown.size)
                    Text(
                        "Rackoon reads as ${if (snapshot.isRoot) "root" else "${userName ?: "the ssh user"}, without sudo"}; these need more access, so they are not counted as passed.",
                        color = c.textMuted, fontSize = 12.sp, lineHeight = 17.sp,
                    )
                }
                items(unknown, key = { it.id }) { FindingRow(it) }
            }
            val passed = sorted(findings.filter { it.severity == SecurityFinding.Severity.PASS })
            if (passed.isNotEmpty()) {
                item {
                    Text("✓ ${passed.size} checks passed · ${if (showPassed) "Hide" else "Show"}", color = c.ok, fontSize = 13.sp,
                         modifier = Modifier.clickable { showPassed = !showPassed }.padding(vertical = 6.dp))
                }
                if (showPassed) items(passed, key = { "pass:" + it.id }) { f ->
                    Column(Modifier.padding(horizontal = 4.dp)) {
                        Text(SecurityChecks.check(f.check)?.title ?: f.check, color = c.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        Text(f.summary, color = c.textMuted, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

private fun sorted(list: List<SecurityFinding>): List<SecurityFinding> {
    val order = SecurityChecks.all.map { it.id }
    return list.sortedWith(compareBy({ it.severity.ordinal }, { order.indexOf(it.check).let { i -> if (i < 0) Int.MAX_VALUE else i } }, { it.id }))
}

@Composable
private fun Heading(title: String, count: Int) {
    val c = Rackoon.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 8.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold, color = c.textPrimary)
        Text("$count", fontSize = 12.sp, color = c.textMuted)
    }
}

@Composable
private fun Note(text: String, color: Color) {
    Text(text, color = color, fontSize = 13.sp, lineHeight = 19.sp,
         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)).padding(12.dp))
}

@Composable
private fun FindingRow(f: SecurityFinding) {
    val c = Rackoon.colors
    var open by rememberSaveable(f.id) { mutableStateOf(false) }
    val check = SecurityChecks.check(f.check)
    val tint = when (f.severity) {
        SecurityFinding.Severity.CRITICAL -> c.danger
        SecurityFinding.Severity.WARNING -> c.warn
        SecurityFinding.Severity.INFO -> c.accent
        SecurityFinding.Severity.UNKNOWN -> c.textMuted
        SecurityFinding.Severity.PASS -> c.ok
    }
    RCard(Modifier.fillMaxWidth()) {
        Column(Modifier.clickable { open = !open }.padding(horizontal = 14.dp, vertical = 11.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatusDot(tint)
                Text(f.summary, color = c.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
            }
            if (open && check != null) {
                Detail("Why it matters", check.why)
                Detail("What you can do", check.advice)
                f.evidence?.let { Detail("What Rackoon read", it, mono = true) }
            }
        }
    }
}

@Composable
private fun Detail(title: String, text: String, mono: Boolean = false) {
    val c = Rackoon.colors
    Column(Modifier.padding(start = 18.dp)) {
        Text(title.uppercase(), fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp, color = c.textMuted)
        Text(text, fontSize = 12.sp, lineHeight = 17.sp, color = c.textPrimary, fontFamily = if (mono) MonoFamily else null)
    }
}

@Composable
private fun PortRow(p: ExposedPort) {
    val c = Rackoon.colors
    val what = listOfNotNull(p.service, p.containers.takeIf { it.isNotEmpty() }?.let { "Docker: " + it.joinToString(", ") }).joinToString(" · ").ifEmpty { "Unknown service" }
    val place = when (p.scope) {
        SecurityScope.ALL -> "Every interface"
        SecurityScope.PUBLIC -> "Public address"
        SecurityScope.LAN -> "Local network"
        SecurityScope.TAILSCALE -> "Tailscale only"
        SecurityScope.LOOPBACK -> "This server only"
    }
    RCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${p.port}/${p.proto}", fontFamily = MonoFamily, fontWeight = FontWeight.Medium, color = c.textPrimary)
                Text(what, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            }
            Text("$place · ${p.addresses.joinToString(", ")}", fontSize = 12.sp, color = c.textMuted)
            if (p.flags.isNotEmpty()) Text(p.flags.joinToString(" · "), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.warn)
        }
    }
}

@Composable
private fun Vulnerabilities(vm: AppViewModel, state: AppViewModel.SecurityUi, on: Boolean, all: Boolean, thisServer: Boolean, serverId: String) {
    val c = Rackoon.colors
    RCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when {
                !on -> {
                    Text("Look up known vulnerabilities (CVEs) in this server's installed packages.", color = c.textPrimary, fontWeight = FontWeight.Medium)
                    Text(PRIVACY, color = c.textSecondary, fontSize = 12.sp, lineHeight = 17.sp)
                    SecondaryButton("Turn On for This Server", { vm.setVulnerabilityLookup(serverId, true) }, Modifier.fillMaxWidth())
                    SecondaryButton("Turn On for All Servers", { vm.setVulnerabilityLookup(null, true) }, Modifier.fillMaxWidth())
                }
                !state.lookupSupported -> Text("The lookup supports Debian and Ubuntu releases; this server is neither (or has no release number).", color = c.textSecondary, fontSize = 13.sp)
                state.vulnerabilityError != null -> Text("Could not look up vulnerabilities: ${state.vulnerabilityError}", color = c.warn, fontSize = 13.sp)
                state.vulnerabilities == null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = c.accent)
                    Text("Asking OSV.dev…", color = c.textSecondary, fontSize = 13.sp)
                }
                else -> {
                    val list = state.vulnerabilities
                    if (list.isEmpty()) Text("OSV.dev knows no vulnerabilities in these package versions.", color = c.textPrimary)
                    VulnerabilityFinding.Status.entries.forEach { status ->
                        val group = list.filter { it.status == status }
                        if (group.isNotEmpty()) {
                            Text(
                                when (status) {
                                    VulnerabilityFinding.Status.FIX_WAITING -> "FIX WAITING IN THE UPDATES"
                                    VulnerabilityFinding.Status.FIX_RELEASED -> "FIXED UPSTREAM: REFRESH THE PACKAGE LISTS"
                                    VulnerabilityFinding.Status.NO_FIX -> "NO FIX RELEASED YET"
                                } + " (${group.size})",
                                fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp, color = c.textSecondary,
                            )
                            group.take(20).forEach { VulnRow(it) }
                            if (group.size > 20) Text("and ${group.size - 20} more", fontSize = 12.sp, color = c.textMuted)
                        }
                    }
                    Text(LIMITS, fontSize = 11.sp, lineHeight = 15.sp, color = c.textMuted)
                }
            }
            if (on) {
                if (thisServer) Text("Turn off for this server", color = c.accent, fontSize = 13.sp, modifier = Modifier.clickable { vm.setVulnerabilityLookup(serverId, false) }.padding(vertical = 4.dp))
                if (all) Text("Turn off for all servers", color = c.accent, fontSize = 13.sp, modifier = Modifier.clickable { vm.setVulnerabilityLookup(null, false) }.padding(vertical = 4.dp))
            }
        }
    }
}

@Composable
private fun VulnRow(f: VulnerabilityFinding) {
    val c = Rackoon.colors
    val tint = when (f.severity) { "critical", "high" -> c.danger; "medium" -> c.warn; else -> c.textSecondary }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(f.severity, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint)
            Text(f.id, fontFamily = MonoFamily, fontSize = 12.sp, color = c.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Text(f.packageName, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = c.textPrimary)
        }
        Text(f.installed + (f.fixed?.let { " → $it" } ?: ""), fontFamily = MonoFamily, fontSize = 11.sp, color = c.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (f.summary.isNotEmpty()) Text(f.summary, fontSize = 12.sp, lineHeight = 16.sp, color = c.textSecondary)
    }
}
