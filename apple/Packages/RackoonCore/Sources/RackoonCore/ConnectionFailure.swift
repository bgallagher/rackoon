import Foundation

/// What one verbose ssh login attempt (`ssh -v … true`) did about authentication, read from its stderr. Pure, so the
/// Mac app can say exactly which keys were offered when a server answers "Permission denied".
public struct SSHAttempt: Sendable, Equatable {
    /// Keys ssh sent to the server, in order: "path (TYPE)" or "comment (TYPE, from ssh-agent)".
    public var offered: [String]
    /// Keys the server said it would accept. A key here that still ended in "Permission denied" could not be used:
    /// in batch mode that means it needs a passphrase nobody could type, or its private file is missing or unreadable.
    public var accepted: [String]
    /// The methods the server allows ("publickey", "password", ...), from its last "Authentications that can continue".
    public var methods: [String]
    /// Problems ssh reported about key files ("Load key …: bad permissions").
    public var problems: [String]

    public init(offered: [String] = [], accepted: [String] = [], methods: [String] = [], problems: [String] = []) {
        self.offered = offered
        self.accepted = accepted
        self.methods = methods
        self.problems = problems
    }

    /// Reads `ssh -v` output. ssh prints each identity as `filename TYPE SHA256:… [explicit] [token|authenticator] [agent]`
    /// (for an agent key the "filename" is its comment, which may hold spaces), for example
    ///   debug1: Offering public key: /Users/me/.ssh/id_rsa RSA SHA256:abc…
    ///   debug1: Offering public key: work laptop ED25519 SHA256:abc… agent
    ///   debug1: Server accepts key: /Users/me/.ssh/id_rsa RSA SHA256:abc…
    ///   debug1: Authentications that can continue: publickey,password
    ///   Load key "/Users/me/.ssh/x": bad permissions
    public static func parse(_ text: String) -> SSHAttempt {
        var attempt = SSHAttempt()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let body = line.hasPrefix("debug1: ") ? String(line.dropFirst(8)) : line
            if let rest = strip("Offering public key: ", from: body) {
                let key = describeKey(rest)
                if !attempt.offered.contains(key) { attempt.offered.append(key) }
            } else if let rest = strip("Server accepts key: ", from: body) {
                let key = describeKey(rest)
                if !attempt.accepted.contains(key) { attempt.accepted.append(key) }
            } else if let rest = strip("Authentications that can continue: ", from: body) {
                attempt.methods = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if body.hasPrefix("Load key ") || body.hasPrefix("Permissions ") || body.hasPrefix("WARNING: UNPROTECTED PRIVATE KEY FILE") {
                if !attempt.problems.contains(body) { attempt.problems.append(body) }
            }
        }
        return attempt
    }

    private static func strip(_ prefix: String, from line: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// "/Users/me/.ssh/id_rsa RSA SHA256:abc" -> "/Users/me/.ssh/id_rsa (RSA)";
    /// "work laptop ED25519 SHA256:abc agent" -> "work laptop (ED25519, from ssh-agent)";
    /// "/Users/me/.ssh/x RSA SHA256:abc explicit" -> "/Users/me/.ssh/x (RSA)".
    static func describeKey(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        var fromAgent = false
        while let last = words.last, notes.contains(last) {
            if last == "agent" { fromAgent = true }
            words.removeLast()
        }
        if let fingerprint = words.last, fingerprint.hasPrefix("SHA256:") || fingerprint.hasPrefix("MD5:") { words.removeLast() }
        guard words.count >= 2, let type = words.last, keyTypes.contains(type) else {
            return words.joined(separator: " ") + (fromAgent ? " (from ssh-agent)" : "")
        }
        words.removeLast()
        let name = words.joined(separator: " ")
        return fromAgent ? "\(name) (\(type), from ssh-agent)" : "\(name) (\(type))"
    }

    private static let notes: Set<String> = ["agent", "authenticator", "token", "explicit"]
    private static let keyTypes: Set<String> = [
        "RSA", "DSA", "ECDSA", "ED25519", "ECDSA-SK", "ED25519-SK", "XMSS",
        "RSA-CERT", "DSA-CERT", "ECDSA-CERT", "ED25519-CERT", "ECDSA-SK-CERT", "ED25519-SK-CERT",
    ]
}

/// A failed connection explained for the Overview: what ssh's message means and what to do about it. The raw message
/// stays on screen beside it, so nothing is hidden. Pure; the Mac app renders it.
public struct ConnectionFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The server refused every key (or had none to refuse).
        case authRefused
        /// No SSH service answered at that address and port.
        case unreachable
        /// The name did not resolve on this machine.
        case unresolved
    }

    public var kind: Kind
    public var headline: String
    public var advice: String

    public init(kind: Kind, headline: String, advice: String) {
        self.kind = kind
        self.headline = headline
        self.advice = advice
    }

    /// True for ssh's "user@host: Permission denied (publickey)." and its variants.
    public static func isAuthRefused(_ message: String) -> Bool {
        message.contains("Permission denied (") || message.contains("Permission denied, please try again")
    }

    /// Nil when the message is not one ssh is known for; the banner then shows the raw text alone.
    public static func explain(_ raw: String, attempt: SSHAttempt? = nil) -> ConnectionFailure? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAuthRefused(text) { return authRefused(attempt) }
        if ["Could not resolve hostname", "nodename nor servname provided", "Name or service not known", "Temporary failure in name resolution"]
            .contains(where: text.contains) {
            return ConnectionFailure(
                kind: .unresolved, headline: "The server's name could not be looked up.",
                advice: "This Mac does not know that name. Check the spelling under Edit Connection…, or use the IP address.")
        }
        if text.contains("Connection refused") {
            return ConnectionFailure(
                kind: .unreachable, headline: "Nothing accepts SSH at that address and port.",
                advice: "The machine answered, but no SSH service is listening there. Check the port under Edit Connection… and that sshd is running on the server.")
        }
        if ["Connection closed by", "kex_exchange_identification", "Connection reset by peer"].contains(where: text.contains) {
            return ConnectionFailure(
                kind: .unreachable, headline: "The server dropped the connection before login.",
                advice: "It may be rate-limiting this Mac (fail2ban), restarting, or not an SSH server at all. Try again in a minute; if it keeps happening, check the address and port under Edit Connection….")
        }
        if ["No route to host", "Network is unreachable", "Connection timed out", "Operation timed out", "Timed out after", "Network is down"]
            .contains(where: text.contains) {
            return ConnectionFailure(
                kind: .unreachable, headline: "Can't reach the server.",
                advice: "Check that the server is on and that this Mac is on the same network or VPN (Tailscale), then try again. The address and port can be changed under Edit Connection….")
        }
        return nil
    }

    private static func authRefused(_ attempt: SSHAttempt?) -> ConnectionFailure {
        var lines: [String] = []
        if let attempt {
            if !attempt.accepted.isEmpty {
                lines.append("The server accepts \(list(attempt.accepted)), but ssh could not use it. Rackoon never prompts, so a key with a passphrase must be loaded into ssh-agent first (ssh-add --apple-use-keychain <file>); or the private key file is missing or unreadable.")
            } else if attempt.offered.isEmpty {
                lines.append("ssh had no key to offer: none of its default names (~/.ssh/id_ed25519, id_rsa…) exists and nothing is loaded in ssh-agent. Choose this server's key file under Edit Connection….")
            } else {
                lines.append("ssh offered \(list(attempt.offered)) and the server accepted none. If this server expects another key, choose its file under Edit Connection…, add a Host entry for it in ~/.ssh/config, or load it with ssh-add.")
            }
            lines += attempt.problems
            if attempt.methods.contains("password") || attempt.methods.contains("keyboard-interactive") {
                lines.append("The server also allows password login, which Rackoon can't use: it never asks for one. Put a key on the server first (ssh-copy-id).")
            }
        } else {
            lines.append("Rackoon logs in with keys only and never asks for a password or passphrase. The key must be one of ssh's default names (~/.ssh/id_ed25519, id_rsa…), be loaded in ssh-agent, be named for this host in ~/.ssh/config, or be chosen under Edit Connection….")
        }
        return ConnectionFailure(kind: .authRefused, headline: "The server refused the login.", advice: lines.joined(separator: " "))
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Checks what the Add and Edit forms typed before it becomes a `Server`. Pure except for the key file's existence.
public enum ServerInput {
    /// Why the fields can't be saved, in the user's words, or nil when they can.
    public static func problem(host: String, user: String, port: String, identityFile: String,
                               fileExists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        let key = identityFile.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "A host is needed." }
        // ssh gets "[user@]host" as one argument: a leading dash would turn it into an option.
        if h.hasPrefix("-") { return "A host can't start with a dash." }
        if h.contains(where: \.isWhitespace) { return "A host can't contain spaces." }
        if u.hasPrefix("-") { return "A user name can't start with a dash." }
        if u.contains(where: \.isWhitespace) || u.contains("@") { return "A user name can't contain spaces or @." }
        if !p.isEmpty, !(Int(p).map { (1...65535).contains($0) } ?? false) { return "The port must be a number from 1 to 65535." }
        if !key.isEmpty {
            if key.hasSuffix(".pub") { return "That is the public half of the key. Choose the private key file (the one without .pub)." }
            if !fileExists(NSString(string: key).expandingTildeInPath) { return "There is no readable file at \(key)." }
        }
        return nil
    }
}

/// How an app with its own SSH client (iOS; Android has the same choice in Kotlin) signs in to a server. The Mac has no
/// such setting: its ssh decides from keys, ssh-agent and ~/.ssh/config.
public enum SignInMethod: String, Sendable, Codable, CaseIterable {
    /// Tailscale SSH: the tailnet identifies the device, so SSH `none` authentication is accepted.
    case tailscale
    case key
    case password
}

extension ConnectionFailure {
    /// The same explanations for an embedded SSH client, which has no `ssh -v` to ask which keys were offered: a refused
    /// login is explained from how the server is signed in to. Matches the messages of `EmbeddedSSHError` and of the
    /// network errors under it, and the rules of Android's `ConnectionFailure`. `device` names the device in the advice
    /// ("iPhone", "iPad"). Nil when the message is not one we know; the card then shows the raw text alone.
    public static func explain(_ raw: String, signIn: SignInMethod?, device: String) -> ConnectionFailure? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ needles: [String]) -> Bool { needles.contains { text.range(of: $0, options: .caseInsensitive) != nil } }
        if has(["Sign-in was refused", "Permission denied", "Authentication failed", "Exhausted available authentication"]) {
            return embeddedAuthRefused(signIn, device: device)
        }
        if has(["Unable to resolve host", "nodename nor servname provided", "Name or service not known",
                "Temporary failure in name resolution", "No address associated with hostname"]) {
            return ConnectionFailure(
                kind: .unresolved, headline: "The server's name could not be looked up.",
                advice: "This \(device) does not know that name. Check the spelling under Edit, or use the IP address. A Tailscale name only resolves while Tailscale is connected.")
        }
        if has(["Connection refused", "ECONNREFUSED"]) {
            return ConnectionFailure(
                kind: .unreachable, headline: "Nothing accepts SSH at that address and port.",
                advice: "The machine answered, but no SSH service is listening there. Check the port under Edit and that sshd is running on the server.")
        }
        if has(["Connection closed", "Connection reset", "Connection lost", "the server closed the connection", "Broken pipe"]) {
            return ConnectionFailure(
                kind: .unreachable, headline: "The server dropped the connection.",
                advice: "It may be rate-limiting this \(device) (fail2ban), restarting, or not an SSH server at all. Try again in a minute; if it keeps happening, check the address and port under Edit.")
        }
        if has(["No route to host", "Network is unreachable", "timed out", "Network is down", "ENETUNREACH", "EHOSTUNREACH"]) {
            return ConnectionFailure(
                kind: .unreachable, headline: "Can't reach the server.",
                advice: "Check that the server is on and that this \(device) is on the same network or VPN (Tailscale), then try again. The address and port can be changed under Edit.")
        }
        return nil
    }

    private static func embeddedAuthRefused(_ signIn: SignInMethod?, device: String) -> ConnectionFailure {
        let advice = switch signIn {
        case .tailscale:
            "Tailscale SSH did not let this user in. Check that this \(device) is connected to Tailscale, that your tailnet policy allows SSH to this server as this user, and that the user name is right (Edit). Or choose a key or a password under Sign-in."
        case .key:
            "The server did not accept the saved key for this user. Check the user name under Edit and that the key's public half is in the server's ~/.ssh/authorized_keys, or choose another key under Sign-in."
        case .password:
            "The server did not accept the saved password for this user. Check the user name and password under Edit. Many servers also turn password login off (PasswordAuthentication no) and only take keys."
        case nil:
            "Check the user name under Edit, and the sign-in method: Tailscale SSH, a private key or a password."
        }
        return ConnectionFailure(kind: .authRefused, headline: "The server refused the login.", advice: advice)
    }
}
