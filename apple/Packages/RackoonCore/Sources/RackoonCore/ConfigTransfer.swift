import Foundation

// Config transfer (spec/config-transfer.md): the `rackoon-config` document, plain and encrypted files, the QR parts and
// the import plan. Kept in step with the Python core (`rackoon/core/config_transfer.py`) and the Kotlin core
// (`ConfigTransfer.kt`) by spec/scenarios/config-codec.json, config-merge.json and spec/fixtures/config/.

/// The crypto and compression the format needs. Core stays Foundation-only and builds on Linux, so the apps inject it
/// (CryptoKit, CommonCrypto and Compression on Apple platforms), the same way the licence check gets its Ed25519 check.
public protocol ConfigCrypto: Sendable {
    func randomBytes(_ count: Int) -> Data
    /// PBKDF2-HMAC-SHA256, 32 bytes.
    func pbkdf2SHA256(password: Data, salt: Data, iterations: Int) throws -> Data
    /// AES-256-GCM: the ciphertext followed by the 16-byte tag.
    func sealAESGCM(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data
    /// Throws `ConfigCryptoFailure.authentication` when the tag does not match.
    func openAESGCM(key: Data, nonce: Data, sealed: Data, aad: Data) throws -> Data
    /// Raw DEFLATE (RFC 1951).
    func deflate(_ data: Data) throws -> Data
    /// Raw DEFLATE; throws `ConfigCryptoFailure.tooLarge` past `limit` bytes and `.corrupt` for bad input.
    func inflate(_ data: Data, limit: Int) throws -> Data
    func sha256(_ data: Data) -> Data
}

public enum ConfigCryptoFailure: Error, Equatable {
    case authentication, tooLarge, corrupt
}

/// `code` is shared by every core (spec/fixtures/config/*.expected.json); the message is this app's own.
public struct ConfigTransferError: Error, Equatable, LocalizedError {
    public let code: String
    public let message: String

    public var errorDescription: String? { message }

    static func damaged(_ why: String) -> ConfigTransferError {
        ConfigTransferError(code: "damaged", message: "This file is damaged or was not made by Rackoon (\(why)).")
    }
    static let notRackoon = ConfigTransferError(code: "notRackoonConfig", message: "This is not a Rackoon configuration file.")
    static let newer = ConfigTransferError(code: "newerVersion",
                                           message: "This configuration was made by a newer version of Rackoon. Update this app and try again.")
    static let tooLarge = ConfigTransferError(code: "tooLarge", message: "This configuration is too large.")
}

public enum ConfigTransfer {
    public static let format = "rackoon-config"
    public static let encryptedFormat = "rackoon-config-encrypted"
    public static let version = 1
    public static let platforms = ["mac", "android", "ios", "web"]
    public static let signInMethods: Set<String> = ["tailscale", "key", "password", "system"]
    public static let iterations = 600_000
    public static let minIterations = 100_000
    public static let maxIterations = 5_000_000
    public static let minPassphrase = 10
    public static let maxInflated = 16 * 1024 * 1024
    static let fileAAD = Data("rackoon-config-encrypted/1".utf8)
    static let qrAAD = Data("rackoon-config-qr/1".utf8)
    public static let maxPartBytes = 450
    public static let maxParts = 99
    static let saltBytes = 16, nonceBytes = 12, tagBytes = 16
    static let qrPayloadVersion: UInt8 = 1
    public static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let base45Alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    public static let hostKeyOrder = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"]
    public static let everywhere = "*"
}

// MARK: - The document

public struct ResolvedAddress: Sendable, Equatable {
    public var host: String
    public var user: String?
    public var port: Int?
    public init(host: String, user: String? = nil, port: Int? = nil) { self.host = host; self.user = user; self.port = port }
}

public struct ConfigServer: Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var user: String?
    public var port: Int?
    public var sshConfigAlias: String?
    public var identityFile: String?
    public var resolved: ResolvedAddress?

    public init(id: String, name: String, host: String, user: String? = nil, port: Int? = nil, sshConfigAlias: String? = nil,
                identityFile: String? = nil, resolved: ResolvedAddress? = nil) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.port = port
        self.sshConfigAlias = sshConfigAlias; self.identityFile = identityFile; self.resolved = resolved
    }

    public init(_ server: Server, resolved: ResolvedAddress? = nil) {
        self.init(id: server.id, name: server.name, host: server.host, user: server.user, port: server.port,
                  sshConfigAlias: server.sshConfigAlias, identityFile: server.identityFile, resolved: resolved)
    }

    /// The saved model. `resolved` is only for the document.
    public var server: Server {
        Server(id: id, name: name, host: host, user: user, port: port, sshConfigAlias: sshConfigAlias, identityFile: identityFile)
    }
}

public struct ConfigHostKey: Sendable, Equatable, Hashable {
    public var host: String
    public var port: Int
    public var type: String
    /// base64 of the wire-format key, as in known_hosts.
    public var key: String
    public init(host: String, port: Int, type: String, key: String) { self.host = host; self.port = port; self.type = type; self.key = key }

    var address: String { "\(host.lowercased()):\(port)" }
}

public struct ConfigSignIn: Sendable, Equatable {
    /// tailscale, key, password or system.
    public var method: String
    public var keyName: String?
    public init(method: String, keyName: String? = nil) { self.method = method; self.keyName = keyName }
}

public struct ConfigServerSettings: Sendable, Equatable {
    /// Icon-choice keys without the server id in front -> icon id ("" = the letter).
    public var icons: [String: String] = [:]
    /// Service id -> shown.
    public var services: [String: Bool] = [:]
    public var vulnerabilityLookup: Bool?
    /// Alert ids without the server id in front (`<source>|<key>`), sorted.
    public var mutedAlerts: [String] = []

    public init(icons: [String: String] = [:], services: [String: Bool] = [:], vulnerabilityLookup: Bool? = nil, mutedAlerts: [String] = []) {
        self.icons = icons; self.services = services; self.vulnerabilityLookup = vulnerabilityLookup
        self.mutedAlerts = Array(Set(mutedAlerts)).sorted()
    }

    public var isEmpty: Bool { icons.isEmpty && services.isEmpty && vulnerabilityLookup == nil && mutedAlerts.isEmpty }
}

public struct ConfigSecret: Sendable, Equatable {
    public var password: String?
    public var privateKey: String?
    public var passphrase: String?
    public var keyName: String?
    public init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil, keyName: String? = nil) {
        self.password = password; self.privateKey = privateKey; self.passphrase = passphrase; self.keyName = keyName
    }
}

public struct ConfigDocument: Sendable, Equatable {
    public var servers: [ConfigServer] = []
    public var hostKeys: [ConfigHostKey] = []
    public var signIn: [String: ConfigSignIn] = [:]
    /// Catalog ids (spec/config-transfer.json, part `preferences`) with values of the catalog's type.
    public var preferences: [String: JSONValue] = [:]
    public var serverSettings: [String: ConfigServerSettings] = [:]
    /// The hex of a `custom:` icon id -> base64 PNG.
    public var customIcons: [String: String] = [:]
    public var secrets: [String: ConfigSecret] = [:]
    public var exportedAt: String?
    public var sourcePlatform: String?
    public var sourceApp: String?

    public init() {}
}

// MARK: - The settings catalog

/// A transferred preference from spec/config-transfer.json (a test checks this list equals the catalog).
public struct ConfigPreference: Sendable, Equatable {
    public enum Kind: String, Sendable { case bool, int, string }
    public let id: String
    public let kind: Kind
    public var values: [JSONValue]? = nil
    public var min: Int? = nil
    public var max: Int? = nil
    public var maxLength: Int? = nil

    public static let all: [ConfigPreference] = [
        ConfigPreference(id: "theme", kind: .string, maxLength: 100),
        ConfigPreference(id: "highlightOutput", kind: .bool),
        ConfigPreference(id: "readOnly", kind: .bool),
        ConfigPreference(id: "startReadOnly", kind: .bool),
        ConfigPreference(id: "autoReadOnly", kind: .string, values: ["never", "idle5", "idle15", "background"].map(JSONValue.string)),
        ConfigPreference(id: "dockerUnlockMinutes", kind: .int, values: [0, 15, 60, 480].map(JSONValue.int)),
        ConfigPreference(id: "alertNotifications", kind: .bool),
        ConfigPreference(id: "terminalFontSize", kind: .int, min: 6, max: 40),
        ConfigPreference(id: "servicesShowHidden", kind: .bool),
        ConfigPreference(id: "filesShowHidden", kind: .bool),
        ConfigPreference(id: "dashboardDockerShowAll", kind: .bool),
        ConfigPreference(id: "vulnerabilityLookupAll", kind: .bool),
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The value if it has this preference's type and limits, else nil (dropped).
    func accept(_ value: JSONValue) -> JSONValue? {
        switch (kind, value) {
        case (.bool, .bool): break
        case (.int, .int(let n)):
            if let min, n < min { return nil }
            if let max, n > max { return nil }
        case (.string, .string(let s)):
            if let maxLength, s.unicodeScalars.count > maxLength { return nil }
        default: return nil
        }
        if let values, !values.contains(value) { return nil }
        return value
    }
}

// MARK: - Reading and writing the document

extension ConfigTransfer {
    private static func port(_ value: JSONValue?, _ place: String) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard case .int(let n) = value, (1...65535).contains(n) else { throw ConfigTransferError.damaged("\(place) has a bad port") }
        return n
    }

    static func isBase64(_ text: String) -> Bool { !text.isEmpty && Data(base64Encoded: text) != nil }

    private static func nonEmpty(_ value: JSONValue?) -> String? { value?.string.flatMap { $0.isEmpty ? nil : $0 } }

    private static func readServer(_ raw: JSONValue, index: Int) throws -> ConfigServer {
        let place = "server \(index + 1)"
        guard let o = raw.object else { throw ConfigTransferError.damaged("\(place) is not an object") }
        guard let id = o["id"]?.string, !id.isEmpty, id.count <= 100, let name = o["name"]?.string,
              let host = o["host"]?.string, !host.isEmpty else { throw ConfigTransferError.damaged("\(place) needs an id, a name and a host") }
        let user = nonEmpty(o["user"])
        let port = try port(o["port"], place)
        if ServerInput.problem(host: host, user: user ?? "", port: "", identityFile: "") != nil
            || host != host.trimmingCharacters(in: .whitespaces) || (user.map { $0 != $0.trimmingCharacters(in: .whitespaces) } ?? false) {
            throw ConfigTransferError.damaged("\(place) has an address Rackoon cannot use")
        }
        var resolved: ResolvedAddress?
        if let r = o["resolved"]?.object {
            let rUser = nonEmpty(r["user"])
            guard let rHost = r["host"]?.string, !rHost.isEmpty,
                  ServerInput.problem(host: rHost, user: rUser ?? "", port: "", identityFile: "") == nil else {
                throw ConfigTransferError.damaged("\(place) has a resolved address Rackoon cannot use")
            }
            resolved = ResolvedAddress(host: rHost, user: rUser, port: try self.port(r["port"], place))
        }
        return ConfigServer(id: id, name: name, host: host, user: user, port: port, sshConfigAlias: nonEmpty(o["sshConfigAlias"]),
                            identityFile: nonEmpty(o["identityFile"]), resolved: resolved)
    }

    private static func isKeyType(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || "@.-".unicodeScalars.contains($0) }
    }

    /// A plain name or address: never a known_hosts pattern (`*` `?` `!`) or list (`,`), which the Mac writes into
    /// ~/.ssh/known_hosts.
    static func isKeyHost(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }

    private static func readHostKey(_ raw: JSONValue, index: Int) throws -> ConfigHostKey {
        let place = "host key \(index + 1)"
        guard let o = raw.object else { throw ConfigTransferError.damaged("\(place) is not an object") }
        let port = try port(o["port"], place)
        guard let host = o["host"]?.string, isKeyHost(host), let port,
              let type = o["type"]?.string, isKeyType(type), let key = o["key"]?.string, isBase64(key) else {
            throw ConfigTransferError.damaged("\(place) is incomplete")
        }
        return ConfigHostKey(host: host, port: port, type: type, key: key)
    }

    private static func readSettings(_ raw: JSONValue, everywhere: Bool) -> ConfigServerSettings {
        guard let o = raw.object else { return ConfigServerSettings() }
        var s = ConfigServerSettings()
        s.services = (o["services"]?.object ?? [:]).compactMapValues(\.bool).filter { !$0.key.isEmpty }
        if everywhere { return s }
        s.icons = (o["icons"]?.object ?? [:]).compactMapValues(\.string).filter { !$0.key.isEmpty }
        s.vulnerabilityLookup = o["vulnerabilityLookup"]?.bool
        s.mutedAlerts = Array(Set((o["mutedAlerts"]?.array ?? []).compactMap { $0.string }.filter { !$0.isEmpty })).sorted()
        return s
    }

    /// The hex of a `custom:` icon id, as `AppIconRef` accepts it.
    private static func isCustomIconID(_ s: String) -> Bool {
        (16...64).contains(s.count) && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Reads a parsed document. `secrets` is true only for an encrypted file; a QR transfer passes `customIcons: false`.
    public static func readDocument(_ json: JSONValue, secrets: Bool, customIcons: Bool = true) throws -> ConfigDocument {
        guard let o = json.object, o["format"]?.string == format else { throw ConfigTransferError.notRackoon }
        guard case .int(let v) = o["version"], v >= 1 else { throw ConfigTransferError.damaged("no version") }
        guard v <= version else { throw ConfigTransferError.newer }
        var doc = ConfigDocument()
        doc.exportedAt = o["exportedAt"]?.string
        if let source = o["source"]?.object {
            doc.sourcePlatform = source["platform"]?.string.flatMap { platforms.contains($0) ? $0 : nil }
            doc.sourceApp = source["app"]?.string
        }

        let rawServers = o["servers"] ?? .array([])
        guard let servers = rawServers.array else { throw ConfigTransferError.damaged("servers is not a list") }
        doc.servers = try servers.enumerated().map { try readServer($1, index: $0) }
        let ids = Set(doc.servers.map(\.id))
        guard ids.count == doc.servers.count else { throw ConfigTransferError.damaged("two servers share an id") }

        guard let keys = (o["hostKeys"] ?? .array([])).array else { throw ConfigTransferError.damaged("hostKeys is not a list") }
        var seen = Set<ConfigHostKey>()
        for (i, raw) in keys.enumerated() {
            let key = try readHostKey(raw, index: i)
            if seen.insert(key).inserted { doc.hostKeys.append(key) }
        }

        for (id, raw) in o["signIn"]?.object ?? [:] {
            guard ids.contains(id), let method = raw["method"]?.string, signInMethods.contains(method) else { continue }
            doc.signIn[id] = ConfigSignIn(method: method, keyName: nonEmpty(raw["keyName"]))
        }
        for (id, raw) in o["preferences"]?.object ?? [:] {
            if let value = ConfigPreference.byID[id]?.accept(raw) { doc.preferences[id] = value }
        }
        for (id, raw) in o["serverSettings"]?.object ?? [:] where ids.contains(id) || id == everywhere {
            let s = readSettings(raw, everywhere: id == everywhere)
            if !s.isEmpty { doc.serverSettings[id] = s }
        }
        if customIcons {
            for (id, raw) in o["customIcons"]?.object ?? [:] {
                if isCustomIconID(id), let png = raw.string, isBase64(png) { doc.customIcons[id] = png }
            }
        }
        if secrets {
            for (id, raw) in o["secrets"]?.object ?? [:] where ids.contains(id) {
                let s = ConfigSecret(password: raw["password"]?.string, privateKey: raw["privateKey"]?.string,
                                     passphrase: raw["passphrase"]?.string, keyName: raw["keyName"]?.string)
                if !(s.password ?? "").isEmpty || !(s.privateKey ?? "").isEmpty { doc.secrets[id] = s }
            }
        }
        return doc
    }

    private static func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs.compactMap { k, v in v.map { (k, $0) } }))
    }

    private static func string(_ s: String?) -> JSONValue? { s.map(JSONValue.string) }
    private static func int(_ n: Int?) -> JSONValue? { n.map(JSONValue.int) }

    static func serverJSON(_ s: ConfigServer) -> JSONValue {
        object([("id", .string(s.id)), ("name", .string(s.name)), ("host", .string(s.host)), ("user", string(s.user)),
                ("port", int(s.port)), ("sshConfigAlias", string(s.sshConfigAlias)), ("identityFile", string(s.identityFile)),
                ("resolved", s.resolved.map { object([("host", .string($0.host)), ("user", string($0.user)), ("port", int($0.port))]) })])
    }

    static func settingsJSON(_ s: ConfigServerSettings) -> JSONValue {
        object([("icons", s.icons.isEmpty ? nil : .object(s.icons.mapValues(JSONValue.string))),
                ("services", s.services.isEmpty ? nil : .object(s.services.mapValues(JSONValue.bool))),
                ("vulnerabilityLookup", s.vulnerabilityLookup.map(JSONValue.bool)),
                ("mutedAlerts", s.mutedAlerts.isEmpty ? nil : .array(Array(Set(s.mutedAlerts)).sorted().map(JSONValue.string)))])
    }

    /// The canonical JSON: what a file holds and what the shared fixtures and scenarios compare.
    public static func documentJSON(_ doc: ConfigDocument, secrets: Bool = true, customIcons: Bool = true) -> JSONValue {
        var out: [String: JSONValue] = ["format": .string(format), "version": .int(version)]
        if let at = doc.exportedAt { out["exportedAt"] = .string(at) }
        if doc.sourcePlatform != nil || doc.sourceApp != nil {
            out["source"] = object([("platform", string(doc.sourcePlatform)), ("app", string(doc.sourceApp))])
        }
        out["servers"] = .array(doc.servers.map(serverJSON))
        out["hostKeys"] = .array(doc.hostKeys.map {
            .object(["host": .string($0.host), "port": .int($0.port), "type": .string($0.type), "key": .string($0.key)])
        })
        out["signIn"] = .object(doc.signIn.mapValues { object([("method", .string($0.method)), ("keyName", string($0.keyName))]) })
        out["preferences"] = .object(doc.preferences)
        out["serverSettings"] = .object(doc.serverSettings.filter { !$0.value.isEmpty }.mapValues(settingsJSON))
        if customIcons, !doc.customIcons.isEmpty { out["customIcons"] = .object(doc.customIcons.mapValues(JSONValue.string)) }
        if secrets, !doc.secrets.isEmpty {
            out["secrets"] = .object(doc.secrets.mapValues {
                object([("password", string($0.password)), ("privateKey", string($0.privateKey)),
                        ("passphrase", string($0.passphrase)), ("keyName", string($0.keyName))])
            })
        }
        return .object(out)
    }
}

// MARK: - Files

extension ConfigTransfer {
    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// Why a passphrase can't be used, or nil.
    public static func passphraseProblem(_ passphrase: String) -> String? {
        nfc(passphrase).unicodeScalars.count < minPassphrase ? "Use a passphrase of at least \(minPassphrase) characters." : nil
    }

    private static func inflate(_ data: Data, _ crypto: ConfigCrypto) throws -> Data {
        do {
            return try crypto.inflate(data, limit: maxInflated)
        } catch ConfigCryptoFailure.tooLarge {
            throw ConfigTransferError.tooLarge
        } catch {
            throw ConfigTransferError.damaged("it does not decompress")
        }
    }

    /// The document as a plain file, which never carries secrets.
    public static func plainFile(_ doc: ConfigDocument) throws -> Data {
        try documentJSON(doc, secrets: false).data(pretty: true) + Data("\n".utf8)
    }

    public static func encryptedFile(_ doc: ConfigDocument, passphrase: String, crypto: ConfigCrypto,
                                     iterations: Int = iterations) throws -> Data {
        if let problem = passphraseProblem(passphrase) { throw ConfigTransferError(code: "passphraseTooShort", message: problem) }
        let salt = crypto.randomBytes(saltBytes), nonce = crypto.randomBytes(nonceBytes)
        let key = try crypto.pbkdf2SHA256(password: Data(nfc(passphrase).utf8), salt: salt, iterations: iterations)
        let sealed = try crypto.sealAESGCM(key: key, nonce: nonce, plaintext: try crypto.deflate(try documentJSON(doc).data()), aad: fileAAD)
        let envelope: JSONValue = .object([
            "format": .string(encryptedFormat), "version": .int(version),
            "kdf": .object(["name": .string("PBKDF2-SHA256"), "iterations": .int(iterations), "salt": .string(salt.base64EncodedString())]),
            "cipher": .string("AES-256-GCM"), "compression": .string("deflate-raw"),
            "nonce": .string(nonce.base64EncodedString()), "ciphertext": .string(sealed.base64EncodedString()),
        ])
        return try envelope.data(pretty: true) + Data("\n".utf8)
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONValue.parse(data))?["format"]?.string == encryptedFormat
    }

    /// A plain or encrypted file. An encrypted one without a passphrase throws `needsPassphrase`.
    public static func readFile(_ data: Data, passphrase: String? = nil, crypto: ConfigCrypto) throws -> ConfigDocument {
        guard let json = try? JSONValue.parse(data) else { throw ConfigTransferError.notRackoon }
        guard let o = json.object, o["format"]?.string == encryptedFormat else { return try readDocument(json, secrets: false) }
        if case .int(let v) = o["version"], v > version { throw ConfigTransferError.newer }
        guard o["version"] == .int(version), let kdf = o["kdf"]?.object, kdf["name"]?.string == "PBKDF2-SHA256",
              o["cipher"]?.string == "AES-256-GCM", o["compression"]?.string == "deflate-raw" else {
            throw ConfigTransferError.damaged("unknown encryption")
        }
        guard case .int(let iterations) = kdf["iterations"], (minIterations...maxIterations).contains(iterations) else {
            throw ConfigTransferError.damaged("bad key settings")
        }
        guard let salt = kdf["salt"]?.string.flatMap({ Data(base64Encoded: $0) }), let nonce = o["nonce"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let sealed = o["ciphertext"]?.string.flatMap({ Data(base64Encoded: $0) }) else { throw ConfigTransferError.damaged("bad base64") }
        guard salt.count == saltBytes, nonce.count == nonceBytes, sealed.count >= tagBytes else { throw ConfigTransferError.damaged("bad sizes") }
        guard let passphrase else { throw ConfigTransferError(code: "needsPassphrase", message: "This file is encrypted. Enter its passphrase.") }
        let key = try crypto.pbkdf2SHA256(password: Data(nfc(passphrase).utf8), salt: salt, iterations: iterations)
        let plain: Data
        do { plain = try crypto.openAESGCM(key: key, nonce: nonce, sealed: sealed, aad: fileAAD) } catch {
            throw ConfigTransferError(code: "wrongPassphrase", message: "Wrong passphrase, or the file was changed.")
        }
        guard let inner = try? JSONValue.parse(try inflate(plain, crypto)) else { throw ConfigTransferError.damaged("the contents are not JSON") }
        return try readDocument(inner, secrets: true)
    }
}

// MARK: - Base45, unlock codes, QR parts

extension ConfigTransfer {
    public static func base45Encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = ""
        var i = 0
        while i + 1 < bytes.count {
            let n = Int(bytes[i]) * 256 + Int(bytes[i + 1])
            out.append(base45Alphabet[n % 45]); out.append(base45Alphabet[(n / 45) % 45]); out.append(base45Alphabet[n / 2025])
            i += 2
        }
        if bytes.count % 2 == 1, let last = bytes.last {
            out.append(base45Alphabet[Int(last) % 45]); out.append(base45Alphabet[Int(last) / 45])
        }
        return out
    }

    public static func base45Decode(_ text: String) -> Data? {
        var values: [Int] = []
        for ch in text {
            guard let i = base45Alphabet.firstIndex(of: ch) else { return nil }
            values.append(i)
        }
        guard values.count % 3 != 1 else { return nil }
        var out = Data()
        var i = 0
        while i < values.count {
            if i + 2 < values.count {
                let n = values[i] + values[i + 1] * 45 + values[i + 2] * 2025
                guard n <= 0xFFFF else { return nil }
                out.append(UInt8(n / 256)); out.append(UInt8(n % 256))
                i += 3
            } else {
                let n = values[i] + values[i + 1] * 45
                guard n <= 0xFF else { return nil }
                out.append(UInt8(n))
                i += 2
            }
        }
        return out
    }

    static func crockford(_ crypto: ConfigCrypto, count: Int) -> String {
        String(crypto.randomBytes(count).map { crockford[Int($0 & 31)] })
    }

    public static func newUnlockCode(_ crypto: ConfigCrypto) -> String { crockford(crypto, count: 10) }

    public static func formatUnlockCode(_ code: String) -> String { "\(code.prefix(5))-\(code.dropFirst(5))" }

    /// The 10 symbols as typed (upper-cased, spaces and hyphens removed, O read as 0, I and L as 1), or nil.
    public static func normalizeUnlockCode(_ text: String) -> String? {
        let s = String(text.uppercased().filter { $0 != " " && $0 != "-" && $0 != "\t" }.map { c -> Character in
            switch c { case "O": "0"; case "I", "L": "1"; default: c }
        })
        guard s.count == 10, s.allSatisfy({ crockford.contains($0) }) else { return nil }
        return s
    }

    public static func qrParts(_ payload: Data, transferID: String, maxPartBytes: Int = maxPartBytes) throws -> [String] {
        let total = max(1, (payload.count + maxPartBytes - 1) / maxPartBytes)
        guard total <= maxParts else {
            throw ConfigTransferError(code: "tooLarge", message: "Too many servers and settings for QR codes. Export a file instead.")
        }
        let size = (payload.count + total - 1) / total
        let bytes = [UInt8](payload)
        return (0..<total).map { n in
            let chunk = Data(bytes[min(n * size, bytes.count)..<min((n + 1) * size, bytes.count)])
            return "RK1:\(transferID):\(n + 1)/\(total):\(base45Encode(chunk))"
        }
    }

    public struct QRPart: Sendable, Equatable {
        public let transferID: String
        public let n: Int
        public let total: Int
        public let data: Data
    }

    static let badPart = ConfigTransferError(code: "badPart", message: "This QR code is not part of a Rackoon transfer.")

    private static func number(_ s: Substring) -> Int? {
        guard (1...2).contains(s.count), s.first != "0", s.allSatisfy(\.isASCII), let n = Int(s) else { return nil }
        return n
    }

    public static func parsePart(_ text: String) throws -> QRPart {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "RK1", fields[1].count == 6, fields[1].allSatisfy({ crockford.contains($0) }) else { throw badPart }
        let counts = fields[2].split(separator: "/", omittingEmptySubsequences: false)
        guard counts.count == 2, let n = number(counts[0]), let total = number(counts[1]), n <= total else { throw badPart }
        guard let data = base45Decode(String(fields[3])), !data.isEmpty else {
            throw ConfigTransferError(code: "badPart", message: "This QR code is damaged.")
        }
        return QRPart(transferID: String(fields[1]), n: n, total: total, data: data)
    }

    public static func qrPayload(_ doc: ConfigDocument, code: String, crypto: ConfigCrypto) throws -> Data {
        let salt = crypto.randomBytes(saltBytes), nonce = crypto.randomBytes(nonceBytes)
        let key = try crypto.pbkdf2SHA256(password: Data(code.utf8), salt: salt, iterations: iterations)
        let body = try crypto.deflate(try documentJSON(doc, secrets: false, customIcons: false).data())
        return Data([qrPayloadVersion]) + salt + nonce + (try crypto.sealAESGCM(key: key, nonce: nonce, plaintext: body, aad: qrAAD))
    }

    /// The unlock code and the QR texts in order.
    public static func qrExport(_ doc: ConfigDocument, crypto: ConfigCrypto, maxPartBytes: Int = maxPartBytes) throws -> (code: String, parts: [String]) {
        let code = newUnlockCode(crypto)
        let transferID = crockford(crypto, count: 6)
        return (code, try qrParts(try qrPayload(doc, code: code, crypto: crypto), transferID: transferID, maxPartBytes: maxPartBytes))
    }

    public static func readQRPayload(_ payload: Data, typedCode: String, crypto: ConfigCrypto) throws -> ConfigDocument {
        guard payload.count >= 1 + saltBytes + nonceBytes + tagBytes, payload.first == qrPayloadVersion else {
            throw ConfigTransferError(code: "badPart", message: "These QR codes are not a Rackoon transfer this app can read.")
        }
        guard let code = normalizeUnlockCode(typedCode) else {
            throw ConfigTransferError(code: "badUnlockCode", message: "An unlock code is 10 letters and digits, shown beside the QR code.")
        }
        let bytes = [UInt8](payload)
        let salt = Data(bytes[1..<1 + saltBytes]), nonce = Data(bytes[1 + saltBytes..<1 + saltBytes + nonceBytes])
        let key = try crypto.pbkdf2SHA256(password: Data(code.utf8), salt: salt, iterations: iterations)
        let plain: Data
        do { plain = try crypto.openAESGCM(key: key, nonce: nonce, sealed: Data(bytes[(1 + saltBytes + nonceBytes)...]), aad: qrAAD) } catch {
            throw ConfigTransferError(code: "wrongUnlockCode", message: "Wrong unlock code.")
        }
        guard let inner = try? JSONValue.parse(try inflate(plain, crypto)) else { throw ConfigTransferError.damaged("the contents are not JSON") }
        return try readDocument(inner, secrets: false, customIcons: false)
    }

    /// `SHA256:` and the unpadded base64 of the key's SHA-256, as `ssh-keygen -l` prints. Nil for bad base64.
    public static func fingerprint(_ keyBase64: String, crypto: ConfigCrypto) -> String? {
        guard let key = Data(base64Encoded: keyBase64) else { return nil }
        return "SHA256:" + crypto.sha256(key).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Keeps scanned QR parts until every one is in.
public struct QRCollector: Sendable {
    public private(set) var transferID: String?
    public private(set) var total = 0
    private var parts: [Int: Data] = [:]

    public init() {}

    /// Adds a scanned part; true when it was new. Throws for a part of another transfer.
    @discardableResult
    public mutating func add(_ text: String) throws -> Bool {
        let part = try ConfigTransfer.parsePart(text)
        if let transferID {
            guard part.transferID == transferID, part.total == total else {
                throw ConfigTransferError(code: "otherTransfer", message: "That code belongs to a different transfer.")
            }
        } else {
            transferID = part.transferID
            total = part.total
        }
        if let old = parts[part.n] {
            guard old == part.data else {
                throw ConfigTransferError(code: "partConflict", message: "Two different codes claim the same place. Start the scan again.")
            }
            return false
        }
        parts[part.n] = part.data
        return true
    }

    public var count: Int { parts.count }
    public var isComplete: Bool { total > 0 && parts.count == total }
    public var missing: [Int] { total == 0 ? [] : (1...total).filter { parts[$0] == nil } }

    public func payload() throws -> Data {
        guard isComplete else { throw ConfigTransferError(code: "missingParts", message: "Some codes have not been scanned yet.") }
        let data = (1...total).reduce(into: Data()) { $0.append(parts[$1]!) }
        guard data.first == ConfigTransfer.qrPayloadVersion,
              data.count >= 1 + ConfigTransfer.saltBytes + ConfigTransfer.nonceBytes + ConfigTransfer.tagBytes else {
            throw ConfigTransferError(code: "badPart", message: "These QR codes are not a Rackoon transfer this app can read.")
        }
        return data
    }
}

// MARK: - Import planning

public struct ConfigServerPlan: Sendable, Equatable {
    public enum Kind: String, Sendable { case new, identical, change }
    /// Fitted to this platform, with its incoming id.
    public let incoming: ConfigServer
    public let kind: Kind
    public let localID: String?
    /// "id" or "address".
    public let matchedBy: String?
    public let changes: [String]

    public var resultID: String { localID ?? incoming.id }
}

public struct ConfigHostKeyPlan: Sendable, Equatable {
    public enum Status: String, Sendable { case add, trusted, blocked, skipped }
    public let key: ConfigHostKey
    public let status: Status
    /// The key this device trusts, when blocked.
    public let trusted: ConfigHostKey?
}

public struct ConfigImportPlan: Sendable, Equatable {
    public let servers: [ConfigServerPlan]
    public let hostKeys: [ConfigHostKeyPlan]
    /// Ids whose incoming value differs from this device's, sorted.
    public let preferences: [String]
    public let readOnlyTurnsOn: Bool
    /// Local server ids that Replace everything would remove.
    public let removed: [String]
    /// Incoming server ids that come with a password or key.
    public let secrets: [String]
}

public struct ConfigImportChoices: Sendable, Equatable {
    public var replace = false
    /// Incoming ids of matched servers to leave as they are here (Keep mine).
    public var keep: Set<String> = []
    public var applyPreferences = true
    public var trustHostKeys = true

    public init(replace: Bool = false, keep: Set<String> = [], applyPreferences: Bool = true, trustHostKeys: Bool = true) {
        self.replace = replace; self.keep = keep; self.applyPreferences = applyPreferences; self.trustHostKeys = trustHostKeys
    }
}

extension ConfigTransfer {
    static let serverFields = ["name", "host", "user", "port", "sshConfigAlias", "identityFile"]

    /// Rule 1: what an incoming server becomes on this platform.
    public static func fit(_ server: ConfigServer, platform: String) -> ConfigServer {
        guard platform != "mac" else { return server }
        var s = server
        if let r = s.resolved {
            s.host = r.host
            s.user = r.user ?? s.user
            s.port = r.port ?? s.port
        }
        s.sshConfigAlias = nil
        s.identityFile = nil
        s.resolved = nil
        return s
    }

    /// `system` (a Mac's own ssh setup) means nothing elsewhere: the server keeps its own sign-in there.
    public static func fit(_ signIn: ConfigSignIn?, platform: String) -> ConfigSignIn? {
        guard let signIn, signIn.method != "system" || platform == "mac" else { return nil }
        return signIn
    }

    private struct Address: Equatable { let host: String, user: String, port: Int }
    private static func address(_ s: ConfigServer) -> Address { Address(host: s.host.lowercased(), user: s.user ?? "", port: s.port ?? 22) }

    private static func differences(_ local: ConfigServer, _ incoming: ConfigServer) -> [String] {
        serverFields.filter { field in
            switch field {
            case "name": local.name != incoming.name
            case "host": local.host.lowercased() != incoming.host.lowercased()
            case "user": (local.user ?? "") != (incoming.user ?? "")
            case "port": (local.port ?? 22) != (incoming.port ?? 22)
            case "sshConfigAlias": (local.sshConfigAlias ?? "") != (incoming.sshConfigAlias ?? "")
            default: (local.identityFile ?? "") != (incoming.identityFile ?? "")
            }
        }
    }

    private static func rank(_ type: String) -> Int { hostKeyOrder.firstIndex(of: type) ?? hostKeyOrder.count }

    public static func planHostKeys(local: [ConfigHostKey], incoming: [ConfigHostKey], platform: String) -> [ConfigHostKeyPlan] {
        let byAddress = Dictionary(grouping: local, by: \.address)
        let single = platform != "mac"
        var chosen: [String: ConfigHostKey] = [:]
        if single {
            // Stable: equal ranks keep the document's order.
            for k in incoming.enumerated().sorted(by: { (rank($0.element.type), $0.offset) < (rank($1.element.type), $1.offset) }).map(\.element)
            where byAddress[k.address] == nil && chosen[k.address] == nil {
                chosen[k.address] = k
            }
        }
        return incoming.map { k in
            let trusted = byAddress[k.address] ?? []
            let sameType = trusted.filter { $0.type == k.type }
            if sameType.contains(where: { $0.key == k.key }) { return ConfigHostKeyPlan(key: k, status: .trusted, trusted: nil) }
            if let first = sameType.first { return ConfigHostKeyPlan(key: k, status: .blocked, trusted: first) }
            if !trusted.isEmpty || (single && chosen[k.address] != k) { return ConfigHostKeyPlan(key: k, status: .skipped, trusted: nil) }
            return ConfigHostKeyPlan(key: k, status: .add, trusted: nil)
        }
    }

    public static func planImport(local: ConfigDocument, incoming: ConfigDocument, platform: String) -> ConfigImportPlan {
        let fitted = incoming.servers.map { fit($0, platform: platform) }
        let localIDs = Set(local.servers.map(\.id))
        var used = Set<String>()
        var matches: [String: (ConfigServer, String)] = [:]
        for s in fitted where localIDs.contains(s.id) {
            matches[s.id] = (local.servers.first { $0.id == s.id }!, "id")
            used.insert(s.id)
        }
        for s in fitted where matches[s.id] == nil {
            if let candidate = local.servers.first(where: { !used.contains($0.id) && address($0) == address(s) }) {
                matches[s.id] = (candidate, "address")
                used.insert(candidate.id)
            }
        }
        let plans = fitted.map { s -> ConfigServerPlan in
            guard let (here, how) = matches[s.id] else {
                return ConfigServerPlan(incoming: s, kind: .new, localID: nil, matchedBy: nil, changes: [])
            }
            let changes = differences(here, s)
            return ConfigServerPlan(incoming: s, kind: changes.isEmpty ? .identical : .change, localID: here.id, matchedBy: how, changes: changes)
        }
        let prefs = incoming.preferences.filter { local.preferences[$0.key] != $0.value }.map(\.key).sorted()
        let turnsOn = incoming.preferences["readOnly"] == .bool(true) && local.preferences["readOnly"] != .bool(true)
        return ConfigImportPlan(servers: plans, hostKeys: planHostKeys(local: local.hostKeys, incoming: incoming.hostKeys, platform: platform),
                                preferences: prefs, readOnlyTurnsOn: turnsOn,
                                removed: local.servers.map(\.id).filter { !used.contains($0) },
                                secrets: fitted.map(\.id).filter { incoming.secrets[$0] != nil })
    }

    private static func merge(_ here: ConfigServerSettings?, _ new: ConfigServerSettings) -> ConfigServerSettings {
        let base = here ?? ConfigServerSettings()
        return ConfigServerSettings(icons: base.icons.merging(new.icons) { $1 }, services: base.services.merging(new.services) { $1 },
                                    vulnerabilityLookup: new.vulnerabilityLookup ?? base.vulnerabilityLookup,
                                    mutedAlerts: base.mutedAlerts + new.mutedAlerts)
    }

    private static func preferences(_ local: [String: JSONValue], _ incoming: [String: JSONValue]) -> [String: JSONValue] {
        var out = local.merging(incoming) { $1 }
        if local["readOnly"] != nil || incoming["readOnly"] != nil {
            out["readOnly"] = .bool(local["readOnly"] == .bool(true) || incoming["readOnly"] == .bool(true))
        }
        return out
    }

    /// The configuration after the import. Its `secrets` are only the imported ones, filed under the ids they now belong
    /// to, for the app to save; `hostKeys` are this device's plus the ones added.
    public static func applyImport(local: ConfigDocument, incoming: ConfigDocument, plan: ConfigImportPlan,
                                   choices: ConfigImportChoices, platform: String) -> ConfigDocument {
        var result = ConfigDocument()
        result.hostKeys = local.hostKeys + (choices.trustHostKeys ? plan.hostKeys.filter { $0.status == .add }.map(\.key) : [])
        result.customIcons = local.customIcons.merging(incoming.customIcons) { $1 }
        result.exportedAt = local.exportedAt
        result.sourcePlatform = local.sourcePlatform
        result.sourceApp = local.sourceApp

        if choices.replace {
            let here = Dictionary(uniqueKeysWithValues: local.servers.map { ($0.id, $0) })
            result.servers = plan.servers.map { p in
                if p.kind == .identical, let id = p.localID, let s = here[id] { return s }
                var s = p.incoming
                s.id = p.resultID
                return s
            }
            for p in plan.servers {
                let source = p.incoming.id, target = p.resultID
                if let s = fit(incoming.signIn[source], platform: platform) { result.signIn[target] = s }
                if let s = incoming.serverSettings[source] { result.serverSettings[target] = s }
                if let s = incoming.secrets[source] { result.secrets[target] = s }
            }
            if let s = incoming.serverSettings[everywhere] { result.serverSettings[everywhere] = s }
            result.preferences = preferences(local.preferences, incoming.preferences)
            return result
        }

        let taken = plan.servers.filter { $0.kind == .new || !choices.keep.contains($0.incoming.id) }
        var updated: [String: ConfigServer] = [:]
        for p in taken where p.kind == .change { if let id = p.localID { updated[id] = p.incoming } }
        result.servers = local.servers.map { s in
            guard var u = updated[s.id] else { return s }
            u.id = s.id
            return u
        } + plan.servers.filter { $0.kind == .new }.map(\.incoming)
        result.signIn = local.signIn
        result.serverSettings = local.serverSettings
        for p in taken {
            let source = p.incoming.id, target = p.resultID
            if let s = fit(incoming.signIn[source], platform: platform) { result.signIn[target] = s }
            if let s = incoming.serverSettings[source] { result.serverSettings[target] = merge(result.serverSettings[target], s) }
            if let s = incoming.secrets[source] { result.secrets[target] = s }
        }
        if choices.applyPreferences {
            result.preferences = preferences(local.preferences, incoming.preferences)
            if let s = incoming.serverSettings[everywhere] { result.serverSettings[everywhere] = merge(result.serverSettings[everywhere], s) }
        } else {
            result.preferences = local.preferences
        }
        return result
    }
}
