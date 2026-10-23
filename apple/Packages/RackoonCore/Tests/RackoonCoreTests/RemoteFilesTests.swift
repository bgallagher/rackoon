import XCTest
@testable import RackoonCore

final class RemoteFilesTests: XCTestCase {
    func testSpecTemplateAndFixture() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(RemoteFiles.listTemplate, commands.first { $0["id"] as? String == "files_list" }?["script"] as? String)

        XCTAssertEqual(RemoteFiles.homeCommand, commands.first { $0["id"] as? String == "files_home" }?["script"] as? String)

        let out = try String(contentsOf: specDir.appendingPathComponent("fixtures/files_list/basic.out.txt"), encoding: .utf8)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: specDir.appendingPathComponent("fixtures/files_list/basic.expected.json"))) as! [String: Any]
        let listing = try XCTUnwrap(RemoteFiles.parseListing(out))
        XCTAssertEqual(listing.path, expected["path"] as? String)
        XCTAssertEqual(listing.truncated, expected["truncated"] as? Bool)
        let entries = expected["entries"] as! [[String: Any]]
        XCTAssertEqual(listing.entries.count, entries.count)
        for (got, want) in zip(listing.entries, entries) {
            XCTAssertEqual(got.name, want["name"] as? String)
            XCTAssertEqual(got.kind.rawValue, want["kind"] as? String)
            XCTAssertEqual(got.linkTarget, want["linkTarget"] as? String)
            XCTAssertEqual(got.linksToDirectory, want["linksToDirectory"] as? Bool)
            XCTAssertEqual(got.size, (want["size"] as? NSNumber)?.int64Value)
            XCTAssertEqual(got.modified.timeIntervalSince1970, (want["modified"] as! NSNumber).doubleValue, accuracy: 0.001)
            XCTAssertEqual(got.permissions, want["permissions"] as? String)
            XCTAssertEqual(got.owner, want["owner"] as? String)
        }
        // Folders and links to folders open like folders.
        XCTAssertEqual(listing.entries.map(\.isDirectory), [true, false, false, false, true, false])
    }

    func testCommandQuotesThePathAndRefusesBadOnes() {
        let command = RemoteFiles.listCommand("/srv/it's here")
        XCTAssertEqual(command?.hasPrefix("cd -P -- '/srv/it'\\''s here' "), true)
        for bad in ["", "relative/path", "/a\nb", "/a\0b"] { XCTAssertNil(RemoteFiles.listCommand(bad), bad) }
    }

    func testParserRejectsGarbageAndHandlesEmptyAndCutOff() {
        XCTAssertNil(RemoteFiles.parseListing(""))
        XCTAssertNil(RemoteFiles.parseListing("not a path\0"))
        XCTAssertEqual(RemoteFiles.parseListing("/empty\0")?.entries.count, 0)
        // A half-written trailing record is ignored rather than guessed at.
        XCTAssertEqual(RemoteFiles.parseListing("/x\0f\0f\05\0")?.entries.count, 0)
        var many = "/big\0"
        for i in 0..<(RemoteFiles.maxEntries + 3) { many += "f\0f\01\01.0\0-rw-r--r--\0u\0f\(i)\0\0" }
        let listing = RemoteFiles.parseListing(many)
        XCTAssertEqual(listing?.entries.count, RemoteFiles.maxEntries)
        XCTAssertEqual(listing?.truncated, true)
    }

    func testTerminalCommand() {
        XCTAssertEqual(RemoteFiles.terminalCommand(in: "/opt/it's"), #"cd '/opt/it'\''s' && exec "${SHELL:-/bin/sh}" -l"#)
        XCTAssertNil(RemoteFiles.terminalCommand(in: "relative"))
    }

    func testPathHelpers() {
        XCTAssertEqual(RemotePath.join("/", "etc"), "/etc")
        XCTAssertEqual(RemotePath.join("/opt/stacks", "web"), "/opt/stacks/web")
        XCTAssertNil(RemotePath.parent(of: "/"))
        XCTAssertEqual(RemotePath.parent(of: "/opt"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/opt/stacks"), "/opt")
        XCTAssertEqual(RemotePath.crumbs("/opt/stacks").map(\.path), ["/", "/opt", "/opt/stacks"])
        XCTAssertEqual(RemotePath.crumbs("/").map(\.name), ["/"])
    }

    func testSessionMapsExitCodesToReadableErrors() async throws {
        let ok = FakeTransport([.success(CommandResult(stdout: "/a\0", exitCode: 0))])
        let listing = try await FilesSession(transport: ok).list("/a")
        XCTAssertEqual(listing.path, "/a")
        for (code, expected) in [(3, RemoteFilesError.notFound("/a")), (4, .permissionDenied("/a"))] {
            let t = FakeTransport([.success(CommandResult(stdout: "", exitCode: Int32(code)))])
            do { _ = try await FilesSession(transport: t).list("/a"); XCTFail("should throw") }
            catch { XCTAssertEqual(error as? RemoteFilesError, expected) }
        }
        let bad = FakeTransport([.success(CommandResult(stdout: "", exitCode: 0))])
        do { _ = try await FilesSession(transport: bad).list("/a"); XCTFail("should throw") }
        catch { XCTAssertTrue(error is RemoteFilesError) }
        let none = FakeTransport([])
        do { _ = try await FilesSession(transport: none).list("nope"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? RemoteFilesError, .invalidPath) }
        XCTAssertTrue(none.commands.isEmpty)
    }
}

/// Runs the remote command in a local /bin/sh, so the transfer scripts are tested for real (no ssh).
final class ShellTransferer: FileTransferring, @unchecked Sendable {
    func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", remoteCommand]
        let input = Pipe(), err = Pipe()
        sh.standardInput = input; sh.standardError = err
        try sh.run()
        switch source {
        case .file(let url, _): try input.fileHandleForWriting.write(contentsOf: Data(contentsOf: url))
        case .folder(let url, _):
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, "--", url.lastPathComponent]
            let out = Pipe(); tar.standardOutput = out
            try tar.run()
            try input.fileHandleForWriting.write(contentsOf: out.fileHandleForReading.readDataToEndOfFile())
            tar.waitUntilExit()
        }
        try input.fileHandleForWriting.close()
        sh.waitUntilExit()
        if sh.terminationStatus != 0 {
            throw TransferError.failed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", remoteCommand]
        let out = Pipe(); sh.standardOutput = out
        try sh.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        guard sh.terminationStatus == 0 else { throw TransferError.failed("status \(sh.terminationStatus)") }
        switch sink {
        case .file(let url): try data.write(to: url)
        case .folder(let into):
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", "-", "-C", into.path]
            let input = Pipe(); tar.standardInput = input
            try tar.run()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            tar.waitUntilExit()
        }
    }
}

final class FileTransferTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rk-xfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // realpath: /var/folders is a symlink on macOS
        root = URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() -> FilesSession {
        FilesSession(transport: FakeTransport([]), transfers: ShellTransferer(), policy: ActionPolicy())
    }
    private func fileSource(_ url: URL) throws -> LocalSource {
        .file(url, bytes: (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
    /// The size of a folder's tar stream, from a real tar (like the app does).
    private func folderSource(_ url: URL) throws -> LocalSource {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, "--", url.lastPathComponent]
        let out = Pipe(); tar.standardOutput = out
        try tar.run()
        let n = out.fileHandleForReading.readDataToEndOfFile().count
        tar.waitUntilExit()
        return .folder(url, bytes: Int64(n))
    }
    private func dir(_ name: String) throws -> URL {
        let u = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testTemplatesEqualSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(FileTransferCommands.uploadFileTemplate, script("files_upload_file"))
        XCTAssertEqual(FileTransferCommands.uploadFolderTemplate, script("files_upload_folder"))
        XCTAssertEqual(FileTransferCommands.downloadFileTemplate, script("files_download_file"))
        XCTAssertEqual(FileTransferCommands.downloadFolderTemplate, script("files_download_folder"))
    }

    func testNamesAreValidatedAndQuoted() {
        XCTAssertNil(FileTransferCommands.uploadFile(directory: "/srv", newName: "a/b", bytes: 1))
        XCTAssertNil(FileTransferCommands.uploadFile(directory: "/srv", newName: "..", bytes: 1))
        XCTAssertNil(FileTransferCommands.uploadFile(directory: "/srv", newName: "two\nlines", bytes: 1))
        XCTAssertNil(FileTransferCommands.uploadFile(directory: "relative", newName: "x", bytes: 1))
        XCTAssertNil(FileTransferCommands.downloadFolder(directory: "/srv", name: ""))
        XCTAssertNil(FileTransferCommands.uploadFile(directory: "/srv", newName: String(repeating: "a", count: 241), bytes: 1))
        XCTAssertNotNil(FileTransferCommands.uploadFile(directory: "/srv", newName: String(repeating: "a", count: 240), bytes: 1))
        XCTAssertEqual(FileTransferCommands.downloadFile(directory: "/srv", name: "it's"), "cat -- '/srv/it'\\''s'")
    }

    func testUploadFileThenDownloadRoundTripsWeirdNamesAndKeepsModeOnOverwrite() async throws {
        let remote = try dir("remote"), local = try dir("local")
        let source = local.appendingPathComponent("my file; $(touch pwned) 'q'.bin")
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let s = session()
        let intent = try XCTUnwrap(s.uploadIntent(try fileSource(source), toDirectory: remote.path, as: source.lastPathComponent))
        XCTAssertEqual(intent.risk, .mutate)
        try await s.upload(try fileSource(source), toDirectory: remote.path, as: source.lastPathComponent, confirmation: try s.confirm(intent), progress: { _ in })
        let landed = remote.appendingPathComponent(source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: landed), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("pwned").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path).count, 1, "no .rackoon-part left behind")

        // Overwriting keeps the existing file's mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: landed.path)
        try Data("new".utf8).write(to: source)
        let second = try XCTUnwrap(s.uploadIntent(try fileSource(source), toDirectory: remote.path, as: source.lastPathComponent))
        try await s.upload(try fileSource(source), toDirectory: remote.path, as: source.lastPathComponent, confirmation: try s.confirm(second), progress: { _ in })
        let mode = try FileManager.default.attributesOfItem(atPath: landed.path)[.posixPermissions] as? Int
        // `chmod --reference` is GNU-only (the servers have it, macOS doesn't): the real-server probe checks this part there.
        let gnu = Process()
        gnu.executableURL = URL(fileURLWithPath: "/bin/chmod"); gnu.arguments = ["--reference=/", "/dev/null"]
        gnu.standardError = FileHandle.nullDevice
        try? gnu.run(); gnu.waitUntilExit()
        if gnu.terminationStatus == 0 { XCTAssertEqual(mode, 0o600) }
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "new")

        let back = try dir("back")
        try await s.download(name: source.lastPathComponent, isDirectory: false, from: remote.path, toLocalDirectory: back,
                             as: source.lastPathComponent, replacing: false, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent(source.lastPathComponent), encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: back.path).count, 1, "no scratch file left behind")
    }

    func testFolderRoundTripAndMerge() async throws {
        try requireShell()
        let remote = try dir("remote"), local = try dir("local")
        let folder = try dir("local/proj dir")
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: folder.appendingPathComponent("sub/b's.txt"))
        let s = session()
        let intent = try XCTUnwrap(s.uploadIntent(try folderSource(folder), toDirectory: remote.path, as: "proj dir"))
        try await s.upload(try folderSource(folder), toDirectory: remote.path, as: "proj dir", confirmation: try s.confirm(intent), progress: { _ in })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("proj dir/sub/b's.txt"), encoding: .utf8), "b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), ["proj dir"], "scratch folder removed")

        // "Keep both": the same folder under another name.
        let copy = try XCTUnwrap(s.uploadIntent(try folderSource(folder), toDirectory: remote.path, as: "proj dir copy"))
        try await s.upload(try folderSource(folder), toDirectory: remote.path, as: "proj dir copy", confirmation: try s.confirm(copy), progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("proj dir copy/a.txt").path))

        // Uploading again to the same name merges (existing extra files stay).
        try Data("keep".utf8).write(to: remote.appendingPathComponent("proj dir/extra.txt"))
        try await s.upload(try folderSource(folder), toDirectory: remote.path, as: "proj dir", confirmation: try s.confirm(intent), progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("proj dir/extra.txt").path))

        let back = try dir("back")
        try await s.download(name: "proj dir", isDirectory: true, from: remote.path, toLocalDirectory: back, as: "proj dir", replacing: false, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("proj dir/sub/b's.txt"), encoding: .utf8), "b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: back.path), ["proj dir"], "scratch folder removed")
    }

    func testDownloadOfASymlinkToAFolderGetsTheFolder() async throws {
        let remote = try dir("remote/releases/v3")
        try Data("hi".utf8).write(to: remote.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("remote/current"), withDestinationURL: remote)
        let back = try dir("back")
        try await session().download(name: "current", isDirectory: true, from: root.appendingPathComponent("remote").path,
                                     toLocalDirectory: back, as: "current", replacing: false, progress: { _ in })
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: back.appendingPathComponent("current").path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("current/a.txt"), encoding: .utf8), "hi")
    }

    func testReplacingKeepsTheOldItemIfThePlacementFails() async throws {
        let remote = try dir("remote"), back = try dir("back")
        try Data("new".utf8).write(to: remote.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: back.appendingPathComponent("f.txt"))
        try await session().download(name: "f.txt", isDirectory: false, from: remote.path, toLocalDirectory: back, as: "f.txt", replacing: true, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("f.txt"), encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: back.path), ["f.txt"], "no scratch left")
    }

    func testUploadIsRefusedWithoutConfirmationAndInReadOnly() async throws {
        let remote = try dir("remote"), local = try dir("local")
        let source = local.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: source)
        let policy = ActionPolicy()
        let s = FilesSession(transport: FakeTransport([]), transfers: ShellTransferer(), policy: policy)
        do { try await s.upload(try fileSource(source), toDirectory: remote.path, as: "f.txt", confirmation: nil, progress: { _ in }); XCTFail("needs confirmation") }
        catch { XCTAssertEqual(error as? PolicyError, .notConfirmed) }
        let intent = try XCTUnwrap(s.uploadIntent(try fileSource(source), toDirectory: remote.path, as: "f.txt"))
        let confirmation = try s.confirm(intent)
        policy.isReadOnly = true   // switched on after the user said yes
        do { try await s.upload(try fileSource(source), toDirectory: remote.path, as: "f.txt", confirmation: confirmation, progress: { _ in }); XCTFail("read-only") }
        catch { XCTAssertEqual(error as? PolicyError, .readOnly) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: remote.path).isEmpty)
    }

    func testUploadRefusesAFolderInTheWayAndCleansUp() async throws {
        try requireShell()
        let remote = try dir("remote"), local = try dir("local")
        _ = try dir("remote/f.txt")
        let source = local.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: source)
        let s = session()
        let intent = try XCTUnwrap(s.uploadIntent(try fileSource(source), toDirectory: remote.path, as: "f.txt"))
        do { try await s.upload(try fileSource(source), toDirectory: remote.path, as: "f.txt", confirmation: try s.confirm(intent), progress: { _ in }); XCTFail("should fail") }
        catch { XCTAssertTrue("\(error)".contains("folder") || error is TransferError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), ["f.txt"])
    }

    func testAShortStreamNeverReplacesTheRealFileOrFolder() throws {
        try requireShell()
        let remote = try dir("remote")
        try Data("ORIGINAL".utf8).write(to: remote.appendingPathComponent("f.txt"))
        func run(_ command: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf abc | (\(command))"]
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        // 3 bytes arrive but 999 were promised: what a cancelled or dropped upload looks like to the server.
        XCTAssertEqual(try run(try XCTUnwrap(FileTransferCommands.uploadFile(directory: remote.path, newName: "f.txt", bytes: 999))), 1)
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("f.txt"), encoding: .utf8), "ORIGINAL")
        XCTAssertEqual(try run(try XCTUnwrap(FileTransferCommands.uploadFolder(directory: remote.path, sourceName: "d", newName: "d", bytes: 999))), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), ["f.txt"], "no part file, scratch folder or partial folder left")
    }
}

/// Runs the remote command in a local /bin/sh.
private final class ShellTransport: SSHTransport, @unchecked Sendable {
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandResult(stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self), exitCode: p.terminationStatus)
    }
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

final class FileOperationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rk-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: tmp.path).resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session(_ policy: ActionPolicy = ActionPolicy()) -> FilesSession { FilesSession(transport: ShellTransport(), policy: policy) }
    private func run(_ op: FileOperation, _ s: FilesSession) async throws {
        let intent = try XCTUnwrap(s.intent(for: op))
        XCTAssertEqual(intent.risk, .mutate)
        try await s.perform(op, confirmation: try s.confirm(intent))
    }
    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }

    func testTemplatesEqualSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(FileOperationCommands.makeFolderTemplate, script("files_mkdir"))
        XCTAssertEqual(FileOperationCommands.renameTemplate, script("files_rename"))
        XCTAssertEqual(FileOperationCommands.deleteFileTemplate, script("files_delete_file"))
        XCTAssertEqual(FileOperationCommands.deleteFolderTemplate, script("files_delete_folder"))
    }

    func testMakeFolderRenameAndDeleteWithOddNames() async throws {
        let s = session()
        try await run(.makeFolder(in: root.path, name: "new dir; $(x) 'q'"), s)
        XCTAssertEqual(try names(), ["new dir; $(x) 'q'"])
        // a taken name is refused, not merged or replaced
        do { try await run(.makeFolder(in: root.path, name: "new dir; $(x) 'q'"), s); XCTFail("taken") }
        catch { XCTAssertTrue("\(error)".contains("taken")) }

        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("y".utf8).write(to: root.appendingPathComponent("b.txt"))
        try await run(.rename(in: root.path, from: "a.txt", to: "c d.txt"), s)
        XCTAssertEqual(try names(), ["b.txt", "c d.txt", "new dir; $(x) 'q'"])
        do { try await run(.rename(in: root.path, from: "b.txt", to: "c d.txt"), s); XCTFail("would replace") }
        catch { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("c d.txt"), encoding: .utf8), "x", "the existing file survived") }

        try await run(.delete(in: root.path, name: "b.txt", isFolder: false), s)
        XCTAssertEqual(try names(), ["c d.txt", "new dir; $(x) 'q'"])
    }

    func testDeleteFolderAndSymlinkSafety() async throws {
        let s = session()
        // Deep enough to be allowed: <root>/outer/inner/f.txt (the temp path itself has several levels).
        let outer = root.appendingPathComponent("outer")
        try FileManager.default.createDirectory(at: outer.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("f".utf8).write(to: outer.appendingPathComponent("inner/f.txt"))
        // a symlink to a folder is removed as a link; the target survives
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("k.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        try await run(.delete(in: root.path, name: "link", isFolder: false), s)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("k.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("link").path))
        try await run(.delete(in: root.path, name: "outer", isFolder: true), s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outer.path))
    }

    func testRefusalsAndPolicy() async throws {
        for path in ["/", "/etc", "/usr/lib", "/home", "/home/brian", "/opt", "/opt/stacks", "/srv/data", "/var/lib/docker/volumes",
                     "/var/lib/mysql", "/var/lib/postgresql/16", "/home/brian/.ssh", "/root/.ssh", "/var/www/html"] {
            XCTAssertNotNil(FileOperationCommands.deleteProblem(folder: path), path)
        }
        XCTAssertNil(FileOperationCommands.deleteProblem(folder: "/opt/stacks/old"))
        XCTAssertNil(FileOperationCommands.deleteProblem(folder: "/home/brian/Downloads"))
        XCTAssertNil(FileOperationCommands.deleteProblem(folder: "/var/www/html/old-site"))
        XCTAssertNil(FileOperationCommands.command(for: .delete(in: "/opt", name: "stacks", isFolder: true)))
        for bad in ["", ".", "..", "a/b", "x\ny"] {
            XCTAssertNil(FileOperationCommands.command(for: .makeFolder(in: "/tmp", name: bad)), bad)
            XCTAssertNil(FileOperationCommands.command(for: .delete(in: "/tmp", name: bad, isFolder: false)), bad)
        }
        XCTAssertNil(FileOperationCommands.command(for: .rename(in: "/tmp", from: "a", to: "a")))
        XCTAssertNil(FileOperationCommands.command(for: .makeFolder(in: "relative", name: "x")))

        let policy = ActionPolicy()
        let s = session(policy)
        let op = FileOperation.makeFolder(in: root.path, name: "nope")
        do { try await s.perform(op, confirmation: nil); XCTFail("needs confirmation") } catch { XCTAssertEqual(error as? PolicyError, .notConfirmed) }
        let c = try s.confirm(try XCTUnwrap(s.intent(for: op)))
        policy.isReadOnly = true
        do { try await s.perform(op, confirmation: c); XCTFail("read-only") } catch { XCTAssertEqual(error as? PolicyError, .readOnly) }
        XCTAssertEqual(try names(), [])
    }
}
