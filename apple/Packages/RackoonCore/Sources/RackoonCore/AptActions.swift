import Foundation

/// State-changing apt operations. Each is a `.mutate` intent, so it needs a confirmation and respects read-only mode.
public enum AptAction: Sendable, Equatable {
    /// `apt-get update`: refreshes the package lists, installs nothing.
    case refresh
    /// `apt-get upgrade --with-new-pkgs`: every available upgrade, including new packages it needs (a new kernel's), no
    /// removals; held packages stay, and Ubuntu's phased updates wait until apt offers them.
    case upgradeAll
    /// Upgrade only these packages (used for "install security updates").
    case upgrade(packages: [String])

    static let prefix = "if [ \"$(id -u)\" -eq 0 ]; then S=; else S='sudo -n'; fi; $S env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get "
    static let options = "-y -o Dpkg::Options::=--force-confold"

    public static let maxPackages = 200

    public var timeout: TimeInterval { self == .refresh ? 300 : 1800 }

    /// The exact command, or nil if a package name is not a valid Debian package name (or the list is empty).
    public var command: String? {
        switch self {
        case .refresh: return Self.prefix + "update"
        case .upgradeAll: return Self.prefix + "upgrade --with-new-pkgs " + Self.options
        case .upgrade(let packages):
            var seen = Set<String>()
            let unique = packages.filter { seen.insert($0).inserted }
            // The cap keeps the command far below any argument-length limit; callers fall back to upgradeAll.
            guard !unique.isEmpty, unique.count <= Self.maxPackages, unique.allSatisfy(Self.isPackageName) else { return nil }
            return Self.prefix + "install --only-upgrade " + Self.options + " " + unique.joined(separator: " ")
        }
    }

    public var intent: Intent? {
        guard let command else { return nil }
        let summary: String
        switch self {
        case .refresh: summary = "Refresh package lists"
        case .upgradeAll: summary = "Install all available updates"
        case .upgrade(let packages): summary = "Install updates for \(packages.count) package\(packages.count == 1 ? "" : "s")"
        }
        return Intent(summary: summary, command: command, risk: .mutate)
    }

    /// The same action for a user whose sudo wants a password (`SudoElevation`): a separate intent, so a yes to the
    /// plain one never authorises it.
    /// `nonce` must be the one the run will use (`SudoCredential`).
    public func passwordIntent(nonce: String) -> Intent? {
        guard let plain = intent, let command = SudoElevation.withPassword(plain.command, nonce: nonce) else { return nil }
        return Intent(summary: plain.summary + " (with sudo password)", command: command, risk: .mutate)
    }

    /// Debian policy: lowercase letters, digits, `+`, `-`, `.`; at least two characters, starting alphanumeric.
    static func isPackageName(_ name: String) -> Bool {
        guard name.count >= 2, let first = name.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "+-.".contains($0)) }
    }

    /// Turns a failure into something a person can act on. apt runs with LC_ALL=C so its messages are English;
    /// sudo's are not, but they always start with "sudo:", which is what we key on. Looks at both streams.
    public static func explain(stdout: String = "", stderr: String, exitCode: Int32) -> String {
        let lines = (stderr + "\n" + stdout).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.contains(where: { $0.hasPrefix("sudo:") }) {
            return "This user can't run apt with sudo without a password. Enter the password when asked, use root, or allow passwordless sudo for apt-get."
        }
        if lines.contains(where: { $0.contains("Could not get lock") || $0.contains("Unable to acquire the dpkg") }) {
            return "Another package manager is running on the server (apt lock held). Try again in a minute."
        }
        if lines.contains(where: { $0.contains("dpkg was interrupted") }) {
            return "A previous install was interrupted. Run `sudo dpkg --configure -a` on the server, then try again."
        }
        // apt's own errors start with "E:"; show those first, otherwise the last lines.
        let errors = lines.filter { $0.hasPrefix("E:") }
        let shown = errors.isEmpty ? Array(lines.suffix(3)) : Array(errors.suffix(3))
        return shown.isEmpty ? "apt-get failed (exit \(exitCode))" : shown.joined(separator: "\n")
    }
}
