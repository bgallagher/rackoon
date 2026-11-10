package com.bgallagher.rackoon.core

/** State-changing apt operations. Each is a MUTATE intent, so it needs a confirmation and respects read-only mode. */
sealed class AptAction {
    /** `apt-get update`: refreshes the package lists, installs nothing. */
    object Refresh : AptAction()

    /** `apt-get upgrade --with-new-pkgs`: every available upgrade, plus new packages it needs, no removals; held packages stay. */
    object UpgradeAll : AptAction()

    /** Upgrade only these packages (used for "install security updates"). */
    data class Upgrade(val packages: List<String>) : AptAction()

    val timeoutMillis: Long get() = if (this is Refresh) 300_000 else 1_800_000

    /** The exact command, or null if a package name is not a valid Debian package name (or the list is empty). */
    val command: String?
        get() = when (this) {
            Refresh -> SpecCommands.script("apt_refresh")
            UpgradeAll -> SpecCommands.script("apt_upgrade")
            is Upgrade -> {
                val unique = packages.distinct()
                // The cap keeps the command far below any argument-length limit; callers fall back to UpgradeAll.
                if (unique.isEmpty() || unique.size > MAX_PACKAGES || !unique.all(::isPackageName)) null
                else Template.fill(SpecCommands.script("apt_upgrade_packages"), mapOf("packages" to unique.joinToString(" ")))
            }
        }

    val intent: Intent?
        get() {
            val command = command ?: return null
            val summary = when (this) {
                Refresh -> "Refresh package lists"
                UpgradeAll -> "Install all available updates"
                is Upgrade -> "Install updates for ${packages.size} package${if (packages.size == 1) "" else "s"}"
            }
            return Intent(summary, command, Risk.MUTATE)
        }

    companion object {
        const val MAX_PACKAGES = 200

        /** Debian policy: lowercase letters, digits, `+`, `-`, `.`; at least two characters, starting alphanumeric. */
        internal fun isPackageName(name: String): Boolean {
            if (name.length < 2) return false
            val first = name.first()
            if (!(first in 'a'..'z' || first in '0'..'9')) return false
            return name.all { it in 'a'..'z' || it in '0'..'9' || it == '+' || it == '-' || it == '.' }
        }

        /**
         * Turns a failure into something a person can act on. apt runs with LC_ALL=C so its messages are English; sudo's are
         * not, but they always start with "sudo:", which is what we key on. Looks at both streams.
         */
        fun explain(stdout: String = "", stderr: String, exitCode: Int): String {
            val lines = (stderr + "\n" + stdout).split('\n').map { it.trimBlanks() }.filter { it.isNotEmpty() }
            if (lines.any { it.startsWith("sudo:") }) {
                return "This user can't run apt with sudo without a password. Use root, or allow passwordless sudo for apt-get."
            }
            if (lines.any { it.contains("Could not get lock") || it.contains("Unable to acquire the dpkg") }) {
                return "Another package manager is running on the server (apt lock held). Try again in a minute."
            }
            if (lines.any { it.contains("dpkg was interrupted") }) {
                return "A previous install was interrupted. Run `sudo dpkg --configure -a` on the server, then try again."
            }
            // apt's own errors start with "E:"; show those first, otherwise the last lines.
            val errors = lines.filter { it.startsWith("E:") }
            val shown = if (errors.isEmpty()) lines.takeLast(3) else errors.takeLast(3)
            return if (shown.isEmpty()) "apt-get failed (exit $exitCode)" else shown.joinToString("\n")
        }
    }
}
