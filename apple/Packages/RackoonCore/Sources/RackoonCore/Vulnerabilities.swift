import Foundation

// Known vulnerabilities in installed packages (docs/security-plan.md, stage S3). Opt-in: the read-only
// `security_packages` command lists installed packages, and only when the user turned the lookup on are the source
// package names and versions sent to OSV.dev (run by Google), from this device, never from the server. Nothing else
// (host names, addresses) is sent. Pure parts are tested against spec/scenarios/vulnerability-report.json and
// spec/scenarios/debian-version.json; the network goes through `OSVClient` so tests replay spec/osv.

// MARK: - Inventory

public struct InstalledPackage: Codable, Equatable, Sendable {
    /// Binary package name, with `:arch` for a foreign architecture.
    public var binary: String
    public var version: String
    /// Advisories are keyed by source package.
    public var source: String
    public var sourceVersion: String
}

public struct PackageInventory: Codable, Equatable, Sendable {
    public struct OS: Codable, Equatable, Sendable {
        public var id: String
        public var like: String
        public var version: String
        public var codename: String
    }
    public var os: OS
    public var packages: [InstalledPackage]

    public static let command = ##"echo '##os'; (. /etc/os-release 2>/dev/null; echo "id=$ID"; echo "like=$ID_LIKE"; echo "version=$VERSION_ID"; echo "codename=$VERSION_CODENAME"); echo '##packages'; dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n' 2>/dev/null | awk -F'\t' '$1 ~ /^ii/ { print $2 "\t" $3 "\t" $4 "\t" $5 }'; true"##

    public static func parse(_ output: String) -> PackageInventory {
        let sections = SecurityParser.sections(output)
        var os: [String: String] = [:]
        for line in sections["os"] ?? [] {
            guard let eq = line.firstIndex(of: "=") else { continue }
            os[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        let packages: [InstalledPackage] = (sections["packages"] ?? []).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            // dpkg leaves the source fields empty for a package that is its own source on very old versions.
            return InstalledPackage(binary: f[0], version: f[1], source: f[2].isEmpty ? f[0] : f[2],
                                    sourceVersion: f[3].isEmpty ? f[1] : f[3])
        }
        return PackageInventory(os: .init(id: os["id"] ?? "", like: os["like"] ?? "", version: os["version"] ?? "",
                                          codename: os["codename"] ?? ""), packages: packages)
    }

    public static func read(_ transport: SSHTransport) async throws -> PackageInventory {
        let result = try await transport.run(command, timeout: 20)
        guard result.exitCode == 0 else {
            throw SessionError.commandFailed(code: result.exitCode, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parse(result.stdout)
    }
}

// MARK: - dpkg version order

public enum DebianVersion {
    /// dpkg's ordering: -1, 0 or 1.
    public static func compare(_ a: String, _ b: String) -> Int {
        let (ea, ua, ra) = split(a), (eb, ub, rb) = split(b)
        if ea != eb { return ea < eb ? -1 : 1 }
        let u = part(ua, ub)
        return u != 0 ? u : part(ra, rb)
    }

    /// epoch, upstream, revision (the last hyphen starts the revision).
    static func split(_ v: String) -> (Int, String, String) {
        var rest = Substring(v)
        var epoch = 0
        if let colon = rest.firstIndex(of: ":"), let e = Int(rest[..<colon]) {
            epoch = e
            rest = rest[rest.index(after: colon)...]
        }
        if let dash = rest.lastIndex(of: "-") {
            return (epoch, String(rest[..<dash]), String(rest[rest.index(after: dash)...]))
        }
        return (epoch, String(rest), "")
    }

    private static func order(_ c: Character?) -> Int {
        guard let c, !c.isASCIIDigit else { return 0 }
        if c == "~" { return -1 }
        if c.isASCII, c.isLetter { return Int(c.asciiValue!) }
        return Int(c.unicodeScalars.first!.value) + 256
    }

    /// dpkg's verrevcmp.
    static func part(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var i = 0, j = 0
        while i < x.count || j < y.count {
            var first = 0
            while (i < x.count && !x[i].isASCIIDigit) || (j < y.count && !y[j].isASCIIDigit) {
                let ac = order(i < x.count ? x[i] : nil), bc = order(j < y.count ? y[j] : nil)
                if ac != bc { return ac < bc ? -1 : 1 }
                i += 1; j += 1
            }
            while i < x.count, x[i] == "0" { i += 1 }
            while j < y.count, y[j] == "0" { j += 1 }
            while i < x.count, x[i].isASCIIDigit, j < y.count, y[j].isASCIIDigit {
                if first == 0 { first = Int(x[i].asciiValue!) - Int(y[j].asciiValue!) }
                i += 1; j += 1
            }
            if i < x.count, x[i].isASCIIDigit { return 1 }
            if j < y.count, y[j].isASCIIDigit { return -1 }
            if first != 0 { return first < 0 ? -1 : 1 }
        }
        return 0
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - OSV

public struct OSVQuery: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var ecosystem: String
    public var version: String
}

/// The parts of an OSV record the report uses.
public struct OSVRecord: Codable, Equatable, Sendable {
    public struct Affected: Codable, Equatable, Sendable {
        public var ecosystem: String
        public var name: String
        /// `fixed` events of its ECOSYSTEM ranges.
        public var fixed: [String]
    }
    public var id: String
    public var modified: String
    public var summary: String
    public var aliases: [String]
    /// OSV's Ubuntu priority (negligible, low, medium, high, critical), when the record has one.
    public var ubuntuPriority: String?
    public var affected: [Affected]
}

public enum OSV {
    public static let batchURL = URL(string: "https://api.osv.dev/v1/querybatch")!
    public static func recordURL(_ id: String) -> URL {
        URL(string: "https://api.osv.dev/v1/vulns/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))!
    }
    /// Queries per querybatch request (the API pages large answers itself).
    public static let batchSize = 500

    /// The OSV ecosystem of a Debian or Ubuntu release; nil for anything else (derivatives, testing/sid, Unraid).
    public static func ecosystem(id: String, version: String) -> String? {
        let parts = version.split(separator: ".").map(String.init)
        switch id {
        case "ubuntu":
            guard parts.count == 2, let year = Int(parts[0]), Int(parts[1]) != nil else { return nil }
            return parts[1] == "04" && year % 2 == 0 ? "Ubuntu:\(version):LTS" : "Ubuntu:\(version)"
        case "debian":
            guard let major = parts.first, Int(major) != nil else { return nil }
            return "Debian:\(major)"
        default:
            return nil
        }
    }

    /// One query per source package and version, sorted by name.
    public static func queries(_ inventory: PackageInventory) -> [OSVQuery] {
        guard let eco = ecosystem(id: inventory.os.id, version: inventory.os.version) else { return [] }
        let unique = Set(inventory.packages.map { OSVQuery(name: $0.source, ecosystem: eco, version: $0.sourceVersion) })
        return unique.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    /// The querybatch request body; `pageTokens` continues the queries that returned one.
    public static func batchBody(_ queries: [OSVQuery], pageTokens: [String?]? = nil) -> Data {
        let items: [[String: Any]] = queries.enumerated().map { i, q in
            var item: [String: Any] = ["package": ["name": q.name, "ecosystem": q.ecosystem], "version": q.version]
            if let token = pageTokens?[i] { item["page_token"] = token }
            return item
        }
        return (try? JSONSerialization.data(withJSONObject: ["queries": items], options: [.sortedKeys])) ?? Data()
    }

    public struct BatchResult: Equatable, Sendable {
        /// Vulnerability ids per query, in query order.
        public var ids: [[String]]
        public var pageTokens: [String?]
    }

    public static func parseBatch(_ data: Data, count: Int) throws -> BatchResult {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OSVError.malformed("not an object") }
        let results = doc["results"] as? [[String: Any]] ?? []
        guard results.count == count else { throw OSVError.malformed("expected \(count) results, got \(results.count)") }
        return BatchResult(
            ids: results.map { ($0["vulns"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } },
            pageTokens: results.map { $0["next_page_token"] as? String })
    }

    public static func parseRecord(_ data: Data) throws -> OSVRecord {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = doc["id"] as? String else {
            throw OSVError.malformed("no id")
        }
        let severity = (doc["severity"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "Ubuntu" }?["score"] as? String
        let affected: [OSVRecord.Affected] = (doc["affected"] as? [[String: Any]] ?? []).compactMap { a in
            guard let package = a["package"] as? [String: Any], let eco = package["ecosystem"] as? String,
                  let name = package["name"] as? String else { return nil }
            let fixed = (a["ranges"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "ECOSYSTEM" }
                .flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["fixed"] as? String } }
            return .init(ecosystem: eco, name: name, fixed: fixed)
        }
        return OSVRecord(id: id, modified: doc["modified"] as? String ?? "", summary: doc["summary"] as? String ?? "",
                         aliases: doc["aliases"] as? [String] ?? [], ubuntuPriority: severity?.lowercased(), affected: affected)
    }
}

public enum OSVError: Error, LocalizedError, Equatable {
    case malformed(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let s): "OSV.dev sent an answer Rackoon could not read (\(s))."
        case .http(let code): "OSV.dev answered with HTTP \(code)."
        }
    }
}

// MARK: - Report

public struct VulnerabilityFinding: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// A pending update reaches the fixed version: install updates.
        case fixWaiting = "fix_waiting"
        /// A fix exists but no pending update reaches it (the package lists may be old).
        case fixReleased = "fix_released"
        /// No fixed version yet.
        case noFix = "no_fix"
    }
    public var id: String
    public var package: String
    public var installed: String
    public var fixed: String?
    public var status: Status
    /// OSV's Ubuntu priority, or "unrated".
    public var severity: String
    public var summary: String
    public var aliases: [String]
    public var binaries: [String]
}

public struct PendingPackage: Equatable, Sendable {
    public var name: String
    public var newVersion: String
    public init(name: String, newVersion: String) {
        self.name = name
        self.newVersion = newVersion
    }
}

public enum VulnerabilityReport {
    public static let severities = ["critical", "high", "medium", "low", "negligible", "unrated"]

    public static func build(inventory: PackageInventory, queries: [OSVQuery], ids: [[String]], records: [String: OSVRecord],
                             pending: [PendingPackage]) -> [VulnerabilityFinding] {
        var binaries: [String: [String]] = [:]
        for p in inventory.packages { binaries[p.source, default: []].append(p.binary) }
        let newVersion = Dictionary(pending.map { ($0.name, $0.newVersion) }, uniquingKeysWith: { a, _ in a })
        var out: [VulnerabilityFinding] = []
        var seen = Set<String>()
        for (query, list) in zip(queries, ids) {
            for id in list {
                guard seen.insert("\(query.name)|\(id)").inserted, let record = records[id],
                      let affected = record.affected.first(where: { $0.ecosystem == query.ecosystem && $0.name == query.name }) else { continue }
                // The lowest fixed version above what is installed (OSV matched the version, but stay safe).
                let fixed = affected.fixed.filter { DebianVersion.compare($0, query.version) > 0 }
                    .min { DebianVersion.compare($0, $1) < 0 }
                if fixed == nil, !affected.fixed.isEmpty { continue }   // every fix is already installed
                let bins = (binaries[query.name] ?? []).sorted()
                let status: VulnerabilityFinding.Status
                if let fixed {
                    let waiting = bins.contains { b in newVersion[b].map { DebianVersion.compare($0, fixed) >= 0 } ?? false }
                    status = waiting ? .fixWaiting : .fixReleased
                } else {
                    status = .noFix
                }
                let priority = record.ubuntuPriority.flatMap { severities.contains($0) ? $0 : nil } ?? "unrated"
                out.append(.init(id: id, package: query.name, installed: query.version, fixed: fixed, status: status,
                                 severity: priority, summary: record.summary, aliases: record.aliases, binaries: bins))
            }
        }
        let statusRank = Dictionary(uniqueKeysWithValues: VulnerabilityFinding.Status.allCases.enumerated().map { ($1, $0) })
        return out.sorted {
            (statusRank[$0.status]!, severities.firstIndex(of: $0.severity)!, $0.id) <
                (statusRank[$1.status]!, severities.firstIndex(of: $1.severity)!, $1.id)
        }
    }

    /// Counts for the screen's summary line.
    public static func counts(_ findings: [VulnerabilityFinding]) -> [VulnerabilityFinding.Status: Int] {
        Dictionary(grouping: findings, by: \.status).mapValues(\.count)
    }
}

// MARK: - Lookup

/// The network, injected: the apps use URLSession, tests replay spec/osv.
public protocol OSVClient: Sendable {
    func post(_ url: URL, body: Data) async throws -> Data
    func get(_ url: URL) async throws -> Data
}

/// Remembers OSV answers for a day, so opening the screen again sends nothing new.
public actor OSVCache {
    public static let lifetime: TimeInterval = 86400
    private var answers: [OSVQuery: ([String], Date)] = [:]
    private var records: [String: (OSVRecord, Date)] = [:]

    public init() {}

    func ids(_ q: OSVQuery, now: Date) -> [String]? {
        guard let (ids, at) = answers[q], now.timeIntervalSince(at) < Self.lifetime else { return nil }
        return ids
    }
    func store(_ q: OSVQuery, _ ids: [String], now: Date) { answers[q] = (ids, now) }
    func record(_ id: String, now: Date) -> OSVRecord? {
        guard let (r, at) = records[id], now.timeIntervalSince(at) < Self.lifetime else { return nil }
        return r
    }
    func store(_ r: OSVRecord, now: Date) { records[r.id] = (r, now) }
}

public enum VulnerabilityLookup {
    /// Asks OSV about every source package (querybatch, following page tokens), fetches each record not cached, and
    /// builds the report. Only names, ecosystems and versions leave the device.
    public static func run(_ inventory: PackageInventory, pending: [PendingPackage], client: OSVClient, cache: OSVCache,
                           now: Date = Date(), concurrency: Int = 8) async throws -> [VulnerabilityFinding] {
        let queries = OSV.queries(inventory)
        var ids: [[String]] = Array(repeating: [], count: queries.count)
        var ask: [Int] = []
        for (i, q) in queries.enumerated() {
            if let cached = await cache.ids(q, now: now) { ids[i] = cached } else { ask.append(i) }
        }
        for chunkStart in stride(from: 0, to: ask.count, by: OSV.batchSize) {
            let chunk = Array(ask[chunkStart..<min(chunkStart + OSV.batchSize, ask.count)])
            var tokens: [String?]? = nil
            var open = chunk
            while !open.isEmpty {
                let qs = open.map { queries[$0] }
                let data = try await client.post(OSV.batchURL, body: OSV.batchBody(qs, pageTokens: tokens))
                let result = try OSV.parseBatch(data, count: qs.count)
                var next: [Int] = [], nextTokens: [String?] = []
                for (k, i) in open.enumerated() {
                    ids[i] += result.ids[k]
                    if let token = result.pageTokens[k] { next.append(i); nextTokens.append(token) }
                }
                open = next
                tokens = nextTokens
            }
            for i in chunk { await cache.store(queries[i], ids[i], now: now) }
        }

        var records: [String: OSVRecord] = [:]
        var missing: [String] = []
        for id in Set(ids.flatMap { $0 }).sorted() {
            if let r = await cache.record(id, now: now) { records[id] = r } else { missing.append(id) }
        }
        try await withThrowingTaskGroup(of: OSVRecord.self) { group in
            var next = 0
            func add() {
                guard next < missing.count else { return }
                let id = missing[next]
                next += 1
                group.addTask { try OSV.parseRecord(try await client.get(OSV.recordURL(id))) }
            }
            for _ in 0..<max(1, concurrency) { add() }
            while let record = try await group.next() {
                records[record.id] = record
                await cache.store(record, now: now)
                add()
            }
        }
        return VulnerabilityReport.build(inventory: inventory, queries: queries, ids: ids, records: records, pending: pending)
    }
}
