import Foundation
import XCTest
@testable import RackoonCore
#if canImport(RackoonAppleCrypto)
import RackoonAppleCrypto
/// The real crypto on Apple hosts. On Linux there is none, and the tests that need it skip.
let configCrypto: ConfigCrypto? = AppleConfigCrypto()
#else
let configCrypto: ConfigCrypto? = nil
#endif

private func requireCrypto() throws -> ConfigCrypto {
    guard let configCrypto else { throw XCTSkip("no ConfigCrypto on this platform") }
    return configCrypto
}

private func hex(_ text: String) -> Data {
    var out = Data()
    var i = text.startIndex
    while i < text.endIndex {
        let j = text.index(i, offsetBy: 2)
        out.append(UInt8(text[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// The shared scenarios in spec/scenarios/config-codec.json and config-merge.json (run from SharedScenarioTests).
enum ConfigScenarios {
    static func read(_ input: JSONValue, source: String) throws -> ConfigDocument {
        try ConfigTransfer.readDocument(input, secrets: source == "encrypted", customIcons: source != "qr")
    }

    static func codec(_ cases: [(String, JSONValue)]) throws {
        for (name, c) in cases {
            switch c["fn"]?.string {
            case "base45":
                let text = c["text"]!.string!
                if c["error"] == .bool(true) {
                    XCTAssertNil(ConfigTransfer.base45Decode(text), name)
                } else {
                    let bytes = hex(c["hex"]!.string!)
                    XCTAssertEqual(ConfigTransfer.base45Encode(bytes), text, name)
                    XCTAssertEqual(ConfigTransfer.base45Decode(text), bytes, name)
                }
            case "unlockCode":
                XCTAssertEqual(ConfigTransfer.normalizeUnlockCode(c["input"]!.string!), c["expect"]?.string, name)
            case "qrSplit":
                XCTAssertEqual(try ConfigTransfer.qrParts(hex(c["hex"]!.string!), transferID: c["transferId"]!.string!,
                                                          maxPartBytes: c["maxPartBytes"]!.int!),
                               c["parts"]!.array!.map { $0.string! }, name)
            case "qrCollect":
                var collector = QRCollector()
                var got: JSONValue
                do {
                    for part in c["parts"]!.array! { try collector.add(part.string!) }
                    got = .object(["hex": .string(hexString(try collector.payload()))])
                } catch let e as ConfigTransferError {
                    got = .object(["error": .string(e.code)])
                }
                XCTAssertEqual(got, .object(c.object!.filter { $0.key == "hex" || $0.key == "error" }), name)
            case "fingerprint":
                guard let crypto = configCrypto else { continue }
                XCTAssertEqual(ConfigTransfer.fingerprint(c["key"]!.string!, crypto: crypto), c["expect"]?.string, name)
            case "readDocument":
                let source = c["source"]!.string!
                var got: JSONValue
                do {
                    let doc = try read(c["input"]!, source: source)
                    got = .object(["document": ConfigTransfer.documentJSON(doc, secrets: source == "encrypted", customIcons: source != "qr")])
                } catch let e as ConfigTransferError {
                    got = .object(["error": .string(e.code)])
                }
                XCTAssertEqual(got, .object(c.object!.filter { $0.key == "document" || $0.key == "error" }), name)
            default:
                XCTFail("\(name): unknown fn")
            }
        }
    }

    static func merge(_ cases: [(String, JSONValue)]) throws {
        for (name, c) in cases {
            let platform = c["platform"]!.string!
            let local = try ConfigTransfer.readDocument(c["local"]!, secrets: true)
            let incoming = try read(c["incoming"]!, source: c["source"]!.string!)
            let plan = ConfigTransfer.planImport(local: local, incoming: incoming, platform: platform)
            let servers: [JSONValue] = plan.servers.map { p in
                var o: [String: JSONValue] = ["id": .string(p.incoming.id), "kind": .string(p.kind.rawValue)]
                if let id = p.localID { o["localId"] = .string(id) }
                if let how = p.matchedBy { o["matchedBy"] = .string(how) }
                if !p.changes.isEmpty { o["changes"] = .array(p.changes.map(JSONValue.string)) }
                return .object(o)
            }
            let got: JSONValue = .object([
                "servers": .array(servers),
                "hostKeys": .array(plan.hostKeys.map {
                    .object(["host": .string($0.key.host), "port": .int($0.key.port), "type": .string($0.key.type), "status": .string($0.status.rawValue)])
                }),
                "preferences": .array(plan.preferences.map(JSONValue.string)), "readOnlyTurnsOn": .bool(plan.readOnlyTurnsOn),
                "removed": .array(plan.removed.map(JSONValue.string)), "secrets": .array(plan.secrets.map(JSONValue.string)),
            ])
            XCTAssertEqual(got, c["plan"], name)
            let o = c["choices"]?.object ?? [:]
            let choices = ConfigImportChoices(replace: o["replace"]?.bool ?? false, keep: Set((o["keep"]?.array ?? []).compactMap(\.string)),
                                              applyPreferences: o["applyPreferences"]?.bool ?? true, trustHostKeys: o["trustHostKeys"]?.bool ?? true)
            let result = ConfigTransfer.applyImport(local: local, incoming: incoming, plan: plan, choices: choices, platform: platform)
            XCTAssertEqual(ConfigTransfer.documentJSON(result), c["result"], name)
        }
    }
}

final class ConfigTransferTests: XCTestCase {
    private let dir = specDir.appendingPathComponent("fixtures/config")

    private func names(_ suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted()
    }

    private func expected(_ name: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("\(name).expected.json")))
    }

    private func outcome(_ read: () throws -> JSONValue) -> JSONValue {
        do { return .object(["document": try read()]) } catch let e as ConfigTransferError {
            return .object(["error": .string(e.code)])
        } catch { return .object(["error": .string("\(error)")]) }
    }

    private func trimmed(_ e: JSONValue) -> JSONValue { .object(e.object!.filter { $0.key == "document" || $0.key == "error" }) }

    /// Every file in spec/fixtures/config (written by tools/config-fixtures from the Python core) reads the same here.
    func testFileFixtures() throws {
        let crypto = try requireCrypto()
        let all = try names(".rackoon")
        XCTAssertGreaterThanOrEqual(all.count, 15)
        for name in all {
            let e = try expected(name)
            let data = try Data(contentsOf: dir.appendingPathComponent("\(name).rackoon"))
            let encrypted = ConfigTransfer.isEncrypted(data)
            let got = outcome {
                ConfigTransfer.documentJSON(try ConfigTransfer.readFile(data, passphrase: e["passphrase"]?.string, crypto: crypto), secrets: encrypted)
            }
            XCTAssertEqual(got, trimmed(e), name)
        }
    }

    func testQRFixtures() throws {
        let crypto = try requireCrypto()
        for name in try names(".qr.json") {
            let e = try expected(name)
            var collector = QRCollector()
            for part in try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("\(name).qr.json")))["parts"]!.array! {
                try collector.add(part.string!)
            }
            let got = outcome {
                ConfigTransfer.documentJSON(try ConfigTransfer.readQRPayload(try collector.payload(), typedCode: e["unlockCode"]!.string!, crypto: crypto),
                                            secrets: false, customIcons: false)
            }
            XCTAssertEqual(got, trimmed(e), name)
        }
    }

    /// Plain documents need no crypto, so they are read on every platform (Linux included).
    func testPlainFixturesWithoutCrypto() throws {
        for name in try names(".rackoon") {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(name).rackoon"))
            guard !ConfigTransfer.isEncrypted(data) else { continue }
            let got = outcome { ConfigTransfer.documentJSON(try ConfigTransfer.readDocument(try JSONValue.parse(data), secrets: false), secrets: false) }
            XCTAssertEqual(got, trimmed(try expected(name)), name)
        }
    }

    private func sample() throws -> ConfigDocument {
        var json = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("mac-plain.rackoon"))).object!
        let second = json["servers"]!.array![1]["id"]!.string!
        json["secrets"] = .object([second: .object(["password": .string("pässwörd")])])
        return try ConfigTransfer.readDocument(.object(json), secrets: true)
    }

    func testAnEncryptedFileRoundTripsWithItsSecrets() throws {
        let crypto = try requireCrypto()
        let doc = try sample()
        let data = try ConfigTransfer.encryptedFile(doc, passphrase: "a passphrase", crypto: crypto, iterations: ConfigTransfer.minIterations)
        XCTAssertTrue(ConfigTransfer.isEncrypted(data))
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "pässwörd"))
        XCTAssertEqual(ConfigTransfer.documentJSON(try ConfigTransfer.readFile(data, passphrase: "a passphrase", crypto: crypto)),
                       ConfigTransfer.documentJSON(doc))
        XCTAssertThrowsError(try ConfigTransfer.readFile(data, crypto: crypto)) { XCTAssertEqual(($0 as? ConfigTransferError)?.code, "needsPassphrase") }
    }

    func testThePassphraseIsComparedAfterUnicodeNormalisation() throws {
        let crypto = try requireCrypto()
        let doc = try sample()
        let data = try ConfigTransfer.encryptedFile(doc, passphrase: "caf\u{e9} au lait!", crypto: crypto, iterations: ConfigTransfer.minIterations)
        XCTAssertEqual(try ConfigTransfer.readFile(data, passphrase: "cafe\u{301} au lait!", crypto: crypto).servers, doc.servers)
    }

    func testAShortPassphraseIsRefused() throws {
        XCTAssertNotNil(ConfigTransfer.passphraseProblem("123456789"))
        XCTAssertNil(ConfigTransfer.passphraseProblem("1234567890"))
        let crypto = try requireCrypto()
        XCTAssertThrowsError(try ConfigTransfer.encryptedFile(try sample(), passphrase: "short", crypto: crypto)) {
            XCTAssertEqual(($0 as? ConfigTransferError)?.code, "passphraseTooShort")
        }
    }

    func testAPlainFileNeverCarriesSecrets() throws {
        let data = try ConfigTransfer.plainFile(try sample())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertNil(text.range(of: "secrets"))
        XCTAssertNil(text.range(of: "pässwörd"))
    }

    func testAQRTransferRoundTripsWithoutSecretsOrCustomIcons() throws {
        let crypto = try requireCrypto()
        let doc = try sample()
        let (code, parts) = try ConfigTransfer.qrExport(doc, crypto: crypto, maxPartBytes: 200)
        XCTAssertEqual(code.count, 10)
        XCTAssertGreaterThan(parts.count, 1)
        let allowed = Set(ConfigTransfer.base45Alphabet + [":", "/"])
        XCTAssertTrue(parts.allSatisfy { $0.allSatisfy(allowed.contains) })
        var collector = QRCollector()
        for part in parts.reversed() { try collector.add(part) }
        let got = try ConfigTransfer.readQRPayload(try collector.payload(), typedCode: ConfigTransfer.formatUnlockCode(code).lowercased(), crypto: crypto)
        XCTAssertTrue(got.secrets.isEmpty)
        XCTAssertTrue(got.customIcons.isEmpty)
        XCTAssertEqual(ConfigTransfer.documentJSON(got), ConfigTransfer.documentJSON(doc, secrets: false, customIcons: false))
    }

    func testTooMuchForQRCodesSaysSo() {
        XCTAssertThrowsError(try ConfigTransfer.qrParts(Data(count: 100 * 450), transferID: "ABC123")) {
            XCTAssertEqual(($0 as? ConfigTransferError)?.code, "tooLarge")
        }
    }

    func testAZipBombIsRefused() throws {
        let crypto = try requireCrypto()
        let bomb = try crypto.deflate(Data(count: ConfigTransfer.maxInflated + 10))
        XCTAssertThrowsError(try crypto.inflate(bomb, limit: ConfigTransfer.maxInflated)) { XCTAssertEqual($0 as? ConfigCryptoFailure, .tooLarge) }
        XCTAssertThrowsError(try crypto.inflate(Data([1, 2, 3, 4]), limit: 100))
    }

    /// The Swift copy of the catalog's preferences must equal spec/config-transfer.json (Python and Kotlin read the file).
    func testThePreferenceListEqualsTheCatalog() throws {
        let catalog = try JSONValue.parse(Data(contentsOf: specDir.appendingPathComponent("config-transfer.json")))
        let prefs = catalog["settings"]!.array!.filter { $0["part"]?.string == "preferences" && $0["transfer"] == .bool(true) }
        XCTAssertEqual(prefs.map { $0["id"]!.string! }, ConfigPreference.all.map(\.id))
        for (spec, swift) in zip(prefs, ConfigPreference.all) {
            XCTAssertEqual(spec["type"]?.string, swift.kind.rawValue, swift.id)
            XCTAssertEqual(spec["values"]?.array, swift.values, swift.id)
            XCTAssertEqual(spec["min"]?.int, swift.min, swift.id)
            XCTAssertEqual(spec["max"]?.int, swift.max, swift.id)
            XCTAssertEqual(spec["maxLength"]?.int, swift.maxLength, swift.id)
        }
    }

    func testJSONValueKeepsFlagsAndNumbersApart() throws {
        XCTAssertEqual(try JSONValue.parse(Data("[true, 1, 1.5, null, \"x\"]".utf8)),
                       .array([.bool(true), .int(1), .double(1.5), .null, .string("x")]))
    }
}
