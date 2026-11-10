package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/** Mirrors `UpdatesSnapshot` in spec/models.schema.json: one parsed reading of the `updates` command. */
@Serializable
data class PendingUpdate(
    val name: String,
    /** apt's suite list, e.g. "noble-updates,noble-security". */
    val suite: String,
    val newVersion: String,
    val oldVersion: String? = null,
    val architecture: String,
    val isSecurity: Boolean,
) {
    val id: String get() = "$name:$architecture"
}

@Serializable
data class UpdatesSnapshot(
    /** Upgrades apt would install now; held, phased and kept-back packages are in [waiting] instead. */
    val packages: List<PendingUpdate>,
    /** Packages pinned with `apt-mark hold`; apt will not upgrade them. */
    val held: List<String>,
    /** Unix time the package lists were last refreshed, when the server says. */
    val refreshedAt: Long? = null,
    val rebootRequired: Boolean,
    /** Upgradable, but apt is not installing them yet: held, deferred by Ubuntu's phased rollout, or kept back. */
    val waiting: List<PendingUpdate> = emptyList(),
    /** Names apt defers for its phased rollout. */
    val phased: List<String> = emptyList(),
) {
    val securityCount: Int get() = packages.count { it.isSecurity }

    enum class WaitingReason { HELD, PHASED, KEPT_BACK }

    fun waitingReason(p: PendingUpdate): WaitingReason = when (p.name) {
        in held -> WaitingReason.HELD
        in phased -> WaitingReason.PHASED
        else -> WaitingReason.KEPT_BACK
    }
}

sealed class UpdatesParseError(message: String) : Exception(message) {
    object NotInstalled : UpdatesParseError("apt is not installed on this server.")
    class Malformed(val detail: String) : UpdatesParseError("Unexpected updates output: $detail")
}

/** Pure parser for the `updates` command output (sections `##apt`, `##upgradable`, `##deferred`, `##held`, `##refreshed`, `##reboot`). */
object UpdatesParser {
    fun parse(output: String): UpdatesSnapshot {
        val sections = OverviewParser.splitSections(output)
        val status = sections["apt"]?.firstOrNull() ?: throw UpdatesParseError.Malformed("no ##apt section")
        if (status == "missing") throw UpdatesParseError.NotInstalled

        val upgradable = (sections["upgradable"] ?: emptyList()).mapNotNull(::parseLine)
        val held = sections["held"] ?: emptyList()
        val (phased, kept) = parseDeferred(sections["deferred"] ?: emptyList())
        val waitingNames = held.toSet() + phased + kept
        val refreshed = sections["refreshed"]?.firstOrNull()?.toLongOrNull()
        return UpdatesSnapshot(
            upgradable.filter { it.name !in waitingNames }, held, refreshed,
            rebootRequired = sections["reboot"]?.firstOrNull() == "yes",
            waiting = upgradable.filter { it.name in waitingNames }, phased = phased,
        )
    }

    /** `phased <name>` / `kept <name>` lines (`:arch` dropped). Unique, in order. */
    internal fun parseDeferred(lines: List<String>): Pair<List<String>, List<String>> {
        val phased = mutableListOf<String>()
        val kept = mutableListOf<String>()
        for (line in lines) {
            val f = line.trim().split(Regex(" +"))
            if (f.size != 2) continue
            val name = f[1].substringBefore(':')
            if (name.isEmpty()) continue
            val target = when (f[0]) { "phased" -> phased; "kept" -> kept; else -> continue }
            if (name !in target) target.add(name)
        }
        return phased to kept
    }

    private val LINE = Regex("^[ ]*(\\S+)[ ]+(\\S+)[ ]+(\\S+)(?:[ ]+(\\S.*))?$")

    /**
     * `name/suite[,suite] new-version arch [upgradable from: old-version]`. Anything else ("Listing...", warnings) is not a
     * package line and is skipped.
     */
    internal fun parseLine(line: String): PendingUpdate? {
        val m = LINE.matchEntire(line) ?: return null
        val (first, version, arch, rest) = m.destructured
        val slash = first.indexOf('/')
        if (slash < 0) return null
        val name = first.substring(0, slash)
        val suite = first.substring(slash + 1)
        if (name.isEmpty() || suite.isEmpty()) return null

        var old: String? = null
        val marker = "upgradable from: "
        val at = rest.indexOf(marker)
        if (at >= 0) {
            val tail = rest.substring(at + marker.length)
            val value = if (tail.endsWith("]")) tail.dropLast(1) else tail
            old = value.ifEmpty { null }
        }
        val isSecurity = suite.split(',').any { it.endsWith("-security") }
        return PendingUpdate(name, suite, version, old, arch, isSecurity)
    }
}
