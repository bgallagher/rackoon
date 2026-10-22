import Foundation

public enum RestartPolicy: String, Sendable, CaseIterable, Equatable {
    case no
    case always
    case unlessStopped = "unless-stopped"
    case onFailure = "on-failure"

    public var label: String {
        switch self {
        case .no: "No"
        case .always: "Always"
        case .unlessStopped: "Unless stopped"
        case .onFailure: "On failure"
        }
    }
}

public struct PortRow: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var host: String
    public var container: String
    public init(host: String = "", container: String = "") {
        self.host = host
        self.container = container
    }
    /// Two rows are equal when their text is; the id only identifies a row on screen.
    public static func == (a: PortRow, b: PortRow) -> Bool { a.host == b.host && a.container == b.container }
    public var isBlank: Bool { host.isEmpty && container.isEmpty }

    /// The host field is `port`, or `address:port` to publish on one address only (an IPv4 address or `${VAR}`).
    public var bindAddress: String? { host.contains(":") ? String(host[..<host.lastIndex(of: ":")!]) : nil }
    public var hostPort: Int? { Int(host.split(separator: ":", omittingEmptySubsequences: false).last ?? "") }
}

public struct VolumeRow: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var source: String
    public var target: String
    public init(source: String = "", target: String = "") {
        self.source = source
        self.target = target
    }
    /// Two rows are equal when their text is; the id only identifies a row on screen.
    public static func == (a: VolumeRow, b: VolumeRow) -> Bool { a.source == b.source && a.target == b.target }
    public var isBlank: Bool { source.isEmpty && target.isEmpty }
}

public struct EnvRow: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String
    public init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
    /// Two rows are equal when their text is; the id only identifies a row on screen.
    public static func == (a: EnvRow, b: EnvRow) -> Bool { a.key == b.key && a.value == b.value }
    public var isBlank: Bool { key.isEmpty && value.isEmpty }
}

/// What the Add container form describes: one service, written as compose YAML (and `.env` lines for its
/// environment). Blank rows are ignored, so the form can always show an empty row to type into.
public struct ContainerSpec: Sendable, Equatable {
    public var name: String
    public var image: String
    public var ports: [PortRow]
    public var volumes: [VolumeRow]
    public var env: [EnvRow]
    public var restart: RestartPolicy

    public init(name: String = "", image: String = "", ports: [PortRow] = [PortRow()],
                volumes: [VolumeRow] = [VolumeRow()], env: [EnvRow] = [EnvRow()],
                restart: RestartPolicy = .unlessStopped) {
        self.name = name
        self.image = image
        self.ports = ports
        self.volumes = volumes
        self.env = env
        self.restart = restart
    }

    public var activePorts: [PortRow] { ports.filter { !$0.isBlank } }
    public var activeVolumes: [VolumeRow] { volumes.filter { !$0.isBlank } }
    public var activeEnv: [EnvRow] { env.filter { !$0.isBlank } }

    // MARK: problems (each is a short message for the field, nil when fine or still empty)

    public var nameProblem: String? {
        if name.isEmpty { return nil }
        return ComposeAction.isServiceName(name) ? nil : "Use letters, digits, - _ and ."
    }

    static let imageCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@-")

    public var imageProblem: String? {
        if image.isEmpty { return nil }
        let valid = image.count <= 255 && image.unicodeScalars.allSatisfy(Self.imageCharacters.contains)
            && image.first.map({ $0.isLetter || $0.isNumber }) == true
        return valid ? nil : "That doesn't look like an image name, such as nginx:alpine"
    }

    public static func portProblem(_ p: PortRow) -> String? {
        func valid(_ n: Int?) -> Bool { n.map { (1...65535).contains($0) } ?? false }
        if p.isBlank { return nil }
        if !valid(p.hostPort) || !valid(Int(p.container)) { return "Ports are numbers from 1 to 65535" }
        if let address = p.bindAddress {
            let ipv4 = address.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            let variable = address.range(of: #"^\$\{[A-Za-z_][A-Za-z0-9_]*\}$"#, options: .regularExpression) != nil
            if !ipv4 && !variable { return "Use port, or address:port with an IPv4 address or ${NAME}" }
        }
        return nil
    }

    public static func volumeProblem(_ v: VolumeRow) -> String? {
        if v.isBlank { return nil }
        let pathLike = v.source.hasPrefix("./") || v.source.hasPrefix("/")
        if !pathLike { return "Use a path such as ./data or /srv/data" }
        if !v.target.hasPrefix("/") { return "The container path must start with /" }
        let text = v.source + v.target
        if text.contains(where: { $0.isNewline || $0 == "\"" || $0 == "'" || $0 == "\\" }) || v.source.contains(":") || v.target.contains(":") {
            return "Paths can't contain quotes, backslashes or colons"
        }
        return nil
    }

    public static func envProblem(_ e: EnvRow) -> String? {
        if e.isBlank { return nil }
        let ok = !e.key.isEmpty && e.key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && !e.key.first!.isNumber
        if !ok { return "Names use letters, digits and _ and can't start with a digit" }
        if e.value.contains(where: \.isNewline) { return "A value must be on one line" }
        return nil
    }

    /// The first problem anywhere in the form, or nil when it can be turned into YAML. An empty name or image counts.
    public var blockingProblem: String? {
        if name.isEmpty { return "Enter a container name" }
        if let p = nameProblem { return p }
        if image.isEmpty { return "Enter an image" }
        if let p = imageProblem { return p }
        if let p = activePorts.lazy.compactMap(Self.portProblem).first { return p }
        if let p = activeVolumes.lazy.compactMap(Self.volumeProblem).first { return p }
        if let p = activeEnv.lazy.compactMap(Self.envProblem).first { return p }
        let keys = activeEnv.map(\.key)
        if Set(keys).count != keys.count { return "An environment name is used twice" }
        return nil
    }

    // MARK: output

    /// The service as compose YAML lines. `baseIndent` is the indent of the service name, `step` the indent per level
    /// (an existing file may use 4 spaces).
    public func yamlLines(baseIndent: Int = 2, step: Int = 2) -> [String] {
        func pad(_ level: Int) -> String { String(repeating: " ", count: baseIndent + step * level) }
        var out = [pad(0) + name + ":", pad(1) + "image: " + Self.scalar(image), pad(1) + "restart: " + (restart == .no ? "\"no\"" : restart.rawValue)]  // bare `no` is a YAML boolean
        if !activePorts.isEmpty {
            out.append(pad(1) + "ports:")
            out += activePorts.map { pad(2) + "- \"\($0.host):\($0.container)\"" }
        }
        if !activeVolumes.isEmpty {
            out.append(pad(1) + "volumes:")
            out += activeVolumes.map { pad(2) + "- " + Self.scalar($0.source + ":" + $0.target) }
        }
        if !activeEnv.isEmpty {
            out.append(pad(1) + "environment:")
            out += activeEnv.map { pad(2) + "\($0.key): ${\($0.key)}" }
        }
        return out
    }

    /// A whole compose file with just this service.
    public var composeText: String { (["services:"] + yamlLines()).joined(separator: "\n") + "\n" }

    /// `.env` lines for the environment rows.
    public var envText: String { activeEnv.map { EnvMerge.line(key: $0.key, value: $0.value) }.joined(separator: "\n") + (activeEnv.isEmpty ? "" : "\n") }

    static func scalar(_ s: String) -> String {
        let plain = !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@-").contains($0) }
        return plain ? s : "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum EnvMerge {
    /// One `KEY=value` line. Values with anything but plain characters are single-quoted (taken literally, no `$`
    /// interpolation), or double-quoted when they contain a single quote.
    static func line(key: String, value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@,+=-").contains($0) }
        if plain { return "\(key)=\(value)" }
        if !value.contains("'") { return "\(key)='\(value)'" }
        return "\(key)=\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Appends the entries whose names the existing `.env` does not define yet. Nothing already there is changed, so
    /// `kept` lists the names that were left alone.
    public static func merge(existing: String, adding entries: [EnvRow]) -> (text: String, kept: [String]) {
        let defined = Set(existing.components(separatedBy: "\n").compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            return line.firstIndex(of: "=").map { String(line[..<$0]).trimmingCharacters(in: .whitespaces) }
        })
        let fresh = entries.filter { !defined.contains($0.key) }
        let kept = entries.filter { defined.contains($0.key) }.map(\.key)
        guard !fresh.isEmpty else { return (existing, kept) }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += fresh.map { line(key: $0.key, value: $0.value) }.joined(separator: "\n") + "\n"
        return (text, kept)
    }
}

public enum ComposeInsertError: Error, Equatable, LocalizedError {
    /// `services:` is written inline (`services: {}`), which can't be extended safely by adding lines.
    case inlineServices
    case serviceExists(String)

    public var errorDescription: String? {
        switch self {
        case .inlineServices: "This file writes services on one line, so a container can't be added automatically. Edit the file by hand."
        case .serviceExists(let n): "This stack already has a service called \(n)."
        }
    }
}

/// Adds a service to the text of an existing compose file, as new lines at the end of the `services:` block, without
/// touching anything else (comments, ordering and indentation of the rest stay exactly as they were).
public enum ComposeInsert {
    public static func services(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let block = servicesBlock(lines), let step = childIndent(lines, block) else { return [] }
        return serviceNames(lines, block, step)
    }

    public static func adding(_ spec: ContainerSpec, to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let block = servicesBlock(lines) else {
            // No services key at all: add one at the end.
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            return (lines + ["services:"] + spec.yamlLines()).joined(separator: "\n") + "\n"
        }
        if block.inline { throw ComposeInsertError.inlineServices }
        let step = childIndent(lines, block) ?? 2
        if serviceNames(lines, block, step).contains(spec.name) { throw ComposeInsertError.serviceExists(spec.name) }
        // After the last real line of the block, so blank lines that separate it from the next key stay where they are.
        let last = (block.start + 1..<block.end).reversed().first { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? block.start
        lines.insert(contentsOf: spec.yamlLines(baseIndent: step, step: step), at: last + 1)
        return lines.joined(separator: "\n")
    }

    struct Block { var start: Int; var end: Int; var inline: Bool }

    static func servicesBlock(_ lines: [String]) -> Block? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("services:") }) else { return nil }
        var rest = String(lines[start].dropFirst("services:".count))
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        let inline = !rest.trimmingCharacters(in: .whitespaces).isEmpty
        // The block runs to the next top-level key (a non-blank line that starts in column 0 and is not a comment).
        let end = (start + 1..<lines.count).first { i in
            guard let c = lines[i].first else { return false }
            return c != " " && c != "\t" && c != "#"
        } ?? lines.count
        return Block(start: start, end: end, inline: inline)
    }

    static func childIndent(_ lines: [String], _ block: Block) -> Int? {
        for i in block.start + 1..<block.end {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return line.prefix { $0 == " " }.count
        }
        return nil
    }

    static func serviceNames(_ lines: [String], _ block: Block, _ step: Int) -> [String] {
        guard step > 0 else { return [] }
        return (block.start + 1..<block.end).compactMap { i -> String? in
            let line = lines[i]
            guard line.prefix(while: { $0 == " " }).count == step else { return nil }
            let body = line.dropFirst(step)
            guard let colon = body.firstIndex(of: ":"), let first = body.first, first != "#", first != "-", first != " " else { return nil }
            return body[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}
