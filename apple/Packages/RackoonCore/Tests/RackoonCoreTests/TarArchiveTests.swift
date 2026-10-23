import Foundation
import XCTest
@testable import RackoonCore

final class TarArchiveTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rk-tar-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A folder with a nested file, an empty folder, a long name, a link and a file of exactly one block.
    private func makeFolder() throws -> URL {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("src/photos", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("2024/summer"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("2024/summer/a.txt"))
        try Data(repeating: 0x41, count: 512).write(to: root.appendingPathComponent("block.bin"))
        try Data((0..<70_000).map { UInt8($0 % 251) }).write(to: root.appendingPathComponent("big.bin"))
        let long = String(repeating: "n", count: 140) + ".txt"
        try Data("long\n".utf8).write(to: root.appendingPathComponent(long))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("latest").path, withDestinationPath: "2024/summer")
        return root
    }

    private func archive(_ entries: [TarEntry], chunk: Int = 4096) async throws -> Data {
        var out = Data()
        try await TarWriter.write(entries, chunkSize: chunk) { out.append($0) }
        return out
    }

    private func extract(_ data: Data, into folder: URL, chunk: Int = 777) throws -> TarExtractor {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let x = TarExtractor(into: folder)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            try x.feed(data.subdata(in: offset..<end))
            offset = end
        }
        try x.finish()
        return x
    }

    func testRoundTripKeepsEveryItem() async throws {
        let source = try makeFolder()
        let entries = try TarWriter.entries(of: source, as: "photos")
        XCTAssertEqual(entries.first?.path, "photos")
        XCTAssertTrue(entries.contains { $0.path == "photos/latest" && $0.kind == .symlink("2024/summer") })
        let data = try await archive(entries)
        XCTAssertEqual(Int64(data.count), TarWriter.size(of: entries), "the size the upload command checks")
        XCTAssertEqual(data.count % 512, 0)

        let out = scratch.appendingPathComponent("out")
        let x = try extract(data, into: out)
        XCTAssertEqual(x.skipped, [])
        let back = out.appendingPathComponent("photos")
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("2024/summer/a.txt"), encoding: .utf8), "hello\n")
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("big.bin")), try Data(contentsOf: source.appendingPathComponent("big.bin")))
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("block.bin")).count, 512)
        XCTAssertTrue(FileManager.default.fileExists(atPath: back.appendingPathComponent(String(repeating: "n", count: 140) + ".txt").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: back.appendingPathComponent("latest").path), "2024/summer")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: back.appendingPathComponent("empty").path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testAFileThatGrewStopsTheUpload() async throws {
        let source = try makeFolder()
        let entries = try TarWriter.entries(of: source, as: "photos")
        try Data("hello, and more\n".utf8).write(to: source.appendingPathComponent("2024/summer/a.txt"))
        do {
            _ = try await archive(entries)
            XCTFail("a changed file must stop the stream")
        } catch let error as TarError {
            XCTAssertEqual(error, .changedWhileSending("photos/2024/summer/a.txt"))
        }
    }

    func testPathsOutsideTheFolderAreRefused() throws {
        for bad in ["/etc/passwd", "../escape.txt", "a/../../escape.txt"] {
            var data = TarWriter.headers(for: TarEntry(path: bad, kind: .file, size: 1))
            data.append(Data([0x41]) + Data(count: 511) + Data(count: 1024))
            XCTAssertThrowsError(try extract(data, into: scratch.appendingPathComponent("o-\(UUID().uuidString.prefix(4))")), bad) {
                XCTAssertEqual($0 as? TarError, .unsafePath(bad))
            }
        }
    }

    func testNothingIsWrittenThroughALinkTheArchiveMade() throws {
        // link -> / then link/etc/x: a classic escape.
        var data = TarWriter.headers(for: TarEntry(path: "d/link", kind: .symlink("/")))
        data.append(TarWriter.headers(for: TarEntry(path: "d/link/tmp/x", kind: .file, size: 1)))
        data.append(Data([0x41]) + Data(count: 511) + Data(count: 1024))
        XCTAssertThrowsError(try extract(data, into: scratch.appendingPathComponent("o"))) {
            XCTAssertEqual($0 as? TarError, .unsafePath("d/link/tmp/x"))
        }
    }

    func testAFileReplacingALinkReplacesTheLinkItself() throws {
        let target = scratch.appendingPathComponent("outside.txt")
        try Data("keep\n".utf8).write(to: target)
        var data = TarWriter.headers(for: TarEntry(path: "d/f", kind: .symlink(target.path)))
        data.append(TarWriter.headers(for: TarEntry(path: "d/f", kind: .file, size: 1)))
        data.append(Data([0x41]) + Data(count: 511) + Data(count: 1024))
        let out = scratch.appendingPathComponent("o")
        _ = try extract(data, into: out)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("d/f"), encoding: .utf8), "A")
    }

    func testATruncatedArchiveIsAnError() async throws {
        let entries = try TarWriter.entries(of: try makeFolder(), as: "photos")
        let data = try await archive(entries)
        XCTAssertThrowsError(try extract(data.prefix(data.count - 1500), into: scratch.appendingPathComponent("o"))) {
            XCTAssertEqual($0 as? TarError, .truncated)
        }
    }

    func testAPaxPathAndABase256SizeAreRead() throws {
        let name = String(repeating: "p", count: 120) + ".txt"
        let record = { (k: String, v: String) -> String in
            let body = " \(k)=\(v)\n"
            var n = body.utf8.count + 2
            while "\(n)\(body)".utf8.count != n { n += 1 }
            return "\(n)\(body)"
        }("path", "dir/" + name)
        var data = TarWriter.header(name: "PaxHeader", mode: 0o644, size: Int64(record.utf8.count), modified: 0, type: UInt8(ascii: "x"), link: "")
        data.append(Data(record.utf8))
        data.append(Data(count: Int(TarWriter.padded(Int64(record.utf8.count))) - record.utf8.count))
        // A regular header whose size field is base-256 (as GNU writes files over 8 GiB).
        var h = [UInt8](TarWriter.header(name: "short", mode: 0o644, size: 3, modified: 0, type: UInt8(ascii: "0"), link: ""))
        for i in 124..<136 { h[i] = 0 }
        h[124] = 0x80; h[135] = 3
        for i in 148..<156 { h[i] = 32 }
        let sum = String(h.reduce(0) { $0 + Int($1) }, radix: 8)
        for (i, b) in Array((String(repeating: "0", count: 6 - sum.count) + sum).utf8).enumerated() { h[148 + i] = b }
        h[154] = 0
        data.append(Data(h))
        data.append(Data("abc".utf8) + Data(count: 509) + Data(count: 1024))
        let out = scratch.appendingPathComponent("o")
        _ = try extract(data, into: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("dir/" + name), encoding: .utf8), "abc")
    }

    func testABadChecksumIsAnError() throws {
        var h = [UInt8](TarWriter.headers(for: TarEntry(path: "a", kind: .file, size: 0)))
        h[0] = UInt8(ascii: "b")
        XCTAssertThrowsError(try extract(Data(h) + Data(count: 1024), into: scratch.appendingPathComponent("o")))
    }

    // MARK: against the system's tar

    func testTheSystemTarUnpacksWhatTheWriterSends() async throws {
        try requireShell()
        let source = try makeFolder()
        let entries = try TarWriter.entries(of: source, as: "photos")
        let file = scratch.appendingPathComponent("w.tar")
        try await archive(entries).write(to: file)
        let out = scratch.appendingPathComponent("sys")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/env", ["tar", "-xf", file.path, "-C", out.path])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("photos/2024/summer/a.txt"), encoding: .utf8), "hello\n")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("photos/big.bin")), try Data(contentsOf: source.appendingPathComponent("big.bin")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("photos/" + String(repeating: "n", count: 140) + ".txt").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("photos/latest").path), "2024/summer")
    }

    func testTheReaderUnpacksWhatTheSystemTarWrites() throws {
        try requireShell()
        let source = try makeFolder()
        let file = scratch.appendingPathComponent("s.tar")
        // The download command: `tar -C <folder> -cf - .`
        try run("/usr/bin/env", ["tar", "-C", source.path, "-cf", file.path, "."])
        let out = scratch.appendingPathComponent("back")
        _ = try extract(try Data(contentsOf: file), into: out, chunk: 1000)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("2024/summer/a.txt"), encoding: .utf8), "hello\n")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("big.bin")), try Data(contentsOf: source.appendingPathComponent("big.bin")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(String(repeating: "n", count: 140) + ".txt").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("latest").path), "2024/summer")
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }
}
