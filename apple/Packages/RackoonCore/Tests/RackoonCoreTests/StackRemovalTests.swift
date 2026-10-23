import Foundation
import XCTest
@testable import RackoonCore

final class StackRemovalTests: XCTestCase {
    /// The temp folder with every symlink resolved (/var is a symlink to /private/var on a Mac), because the delete's guard
    /// compares real paths. Foundation's resolvingSymlinksInPath maps /private/var back to /var, so use realpath.
    private func realTemporaryDirectory() -> URL {
        let path = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(path, nil) else { return FileManager.default.temporaryDirectory }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func stack(dir: String = "/opt/stacks/media", files: [String]? = nil, standalone: Bool = false, name: String = "media") -> DockerStack {
        let f = files ?? [dir + "/compose.yaml"]
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none", status: "Up",
                                ports: [], project: name, service: "web", workingDir: dir, configFile: f.first, configFiles: f)
        return DockerStack(name: name, workingDir: dir, configFile: f.first, configFiles: f, containers: [c], isStandalone: standalone)
    }

    func testTemplateMatchesSpecAndCommandsAreExact() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(StackRemoval.template, commands.first { $0["id"] as? String == "compose_down" }?["script"] as? String)
        XCTAssertEqual(StackRemoval.folderStep, commands.first { $0["id"] as? String == "compose_down_folder" }?["script"] as? String)
        let base = "cd '/opt/stacks/media' && docker compose -p media -f '/opt/stacks/media/compose.yaml' down --remove-orphans"
        XCTAssertEqual(StackRemoval().command(for: stack()), base)
        XCTAssertEqual(StackRemoval(removeVolumes: true).command(for: stack()), base + " -v")
        let folder = StackRemoval(deleteFolder: true).command(for: stack()) ?? ""
        XCTAssertTrue(folder.hasPrefix(base + " && cd / && { [ -f '/opt/stacks/media/compose.yaml' ] || {"), folder)
        XCTAssertTrue(folder.contains("[ ! -L '/opt/stacks/media' ] || {"), folder)
        XCTAssertTrue(folder.contains("R=$(readlink -f -- '/opt/stacks/media')"), folder)
        XCTAssertTrue(folder.contains("case \"$(readlink -f -- '/opt/stacks/media/compose.yaml')\" in \"$R\"/*) true;;"), folder)
        XCTAssertTrue(folder.contains("rm -rf -- '/opt/stacks/media' || { [ \"$(id -u)\" -ne 0 ] && sudo -n rm -rf -- '/opt/stacks/media'; }"), folder)
        XCTAssertEqual(StackRemoval(removeVolumes: true, deleteFolder: true).intent(for: stack())?.summary, "Delete stack media and its folder")
        XCTAssertEqual(StackRemoval().intent(for: stack())?.risk, .mutate)
    }

    func testFolderDeletionIsRefusedForSystemAndHomeFolders() {
        for dir in ["/", "/opt", "/home", "/home/brian", "/root", "/var", "/var/lib", "/var/lib/docker", "/usr/local", "/etc", "/tmp", "/srv",
                    "/opt/../etc", "/opt/./x", "/opt//x", "/opt/stacks/", "/data", "/Users/brian", "/mnt/disk", "/media/usb", "/usr/local/bin",
                    "/var/lib/docker/volumes", "/var/lib/docker", "/etc/stacks/x", "/boot/x", "/snap/x"] {
            let s = stack(dir: dir, files: [dir.hasSuffix("/") ? dir + "compose.yaml" : dir + "/compose.yaml"])
            XCTAssertNotNil(StackRemoval.folderProblem(for: s), dir)
            XCTAssertNil(StackRemoval(deleteFolder: true).command(for: s), dir)
        }
        for dir in ["/opt/stacks/media", "/opt/media", "/srv/media", "/home/brian/stacks/media", "/mnt/data/stacks/x", "/data/media", "/Users/brian/stacks"] {
            XCTAssertNil(StackRemoval.folderProblem(for: stack(dir: dir)), dir)
        }
        // A compose file outside the folder, or an unknown folder: no folder deletion, but plain removal is still fine.
        let outside = stack(files: ["/opt/stacks/media/compose.yaml", "/etc/other.yaml"])
        XCTAssertNotNil(StackRemoval.folderProblem(for: stack(files: ["/opt/stacks/media/../../x/compose.yaml"])), "a .. inside a compose file path")
        XCTAssertNotNil(StackRemoval.folderProblem(for: stack(files: ["/opt/stacks/media/./compose.yaml"])))
        XCTAssertNotNil(StackRemoval.folderProblem(for: outside))
        XCTAssertNil(StackRemoval(deleteFolder: true).command(for: outside))
        XCTAssertNotNil(StackRemoval(removeVolumes: true).command(for: outside))
    }

    func testStandaloneAndUnsafeProjectsAreRefused() {
        XCTAssertNil(StackRemoval().command(for: stack(standalone: true)))
        XCTAssertNil(StackRemoval().command(for: stack(name: "media; reboot")))
        XCTAssertNil(StackRemoval().command(for: stack(dir: "relative", files: ["relative/compose.yaml"])))
    }

    func testRemovalNeedsConfirmationAndHonoursReadOnly() throws {
        let policy = ActionPolicy()
        let session = DockerSession(transport: FakeTransport([]), policy: policy)
        XCTAssertNoThrow(try session.confirm(StackRemoval(), stack: stack()))
        XCTAssertThrowsError(try session.confirm(StackRemoval(deleteFolder: true), stack: stack(dir: "/opt")))
        policy.isReadOnly = true
        XCTAssertThrowsError(try session.confirm(StackRemoval(), stack: stack()))
    }

    // MARK: the real command under /bin/sh with a stub `docker`

    private func run(_ removal: StackRemoval, dir: URL, dockerExit: Int32) throws -> Int32 { try runCapturing(removal, dir: dir, dockerExit: dockerExit).code }

    private func runCapturing(_ removal: StackRemoval, dir: URL, dockerExit: Int32) throws -> (code: Int32, out: String) {
        let bin = dir.deletingLastPathComponent().appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let stub = bin.appendingPathComponent("docker")
        try "#!/bin/sh\nexit \(dockerExit)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let s = stack(dir: dir.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try XCTUnwrap(removal.command(for: s))]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    func testFolderIsDeletedOnlyAfterDownSucceedsAndOnlyWithItsComposeFile() throws {
        try requireShell()
        // Resolved, because the guard compares real paths and /var is a symlink to /private/var on a Mac.
        let root = realTemporaryDirectory().appendingPathComponent("rk-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, compose: Bool) throws -> URL {
            let d = root.appendingPathComponent("stacks/\(name)")
            try FileManager.default.createDirectory(at: d.appendingPathComponent("data"), withIntermediateDirectories: true)
            try "x".write(to: d.appendingPathComponent("data/file"), atomically: true, encoding: .utf8)
            if compose { try "services: {}".write(to: d.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8) }
            return d
        }
        let ok = try make("ok", compose: true)
        XCTAssertEqual(try run(StackRemoval(deleteFolder: true), dir: ok, dockerExit: 0), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok.path), "folder with its data is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stacks").path), "the parent is untouched")

        let failing = try make("failing", compose: true)
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: failing, dockerExit: 1), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failing.appendingPathComponent("data/file").path), "down failed: nothing deleted")

        let noCompose = try make("nocompose", compose: false)
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: noCompose, dockerExit: 0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noCompose.appendingPathComponent("data/file").path), "no compose file: folder is not emptied")

        let keep = try make("keep", compose: true)
        XCTAssertEqual(try run(StackRemoval(), dir: keep, dockerExit: 0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.appendingPathComponent("compose.yaml").path), "plain removal keeps the files")
    }

    func testASymlinkCannotRedirectTheDelete() throws {
        try requireShell()
        let root = realTemporaryDirectory().appendingPathComponent("rk-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // The stack folder is a symlink to a precious folder: nothing in it may be deleted.
        let precious = root.appendingPathComponent("precious")
        try fm.createDirectory(at: precious, withIntermediateDirectories: true)
        try "services: {}".write(to: precious.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("stacks"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("stacks/linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: precious)
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: link, dockerExit: 0), 0)
        XCTAssertTrue(fm.fileExists(atPath: precious.appendingPathComponent("compose.yaml").path))

        // The compose file is a symlink to a file outside the folder: the folder is not deleted either.
        let real = root.appendingPathComponent("stacks/real")
        try fm.createDirectory(at: real.appendingPathComponent("data"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: real.appendingPathComponent("compose.yaml"), withDestinationURL: precious.appendingPathComponent("compose.yaml"))
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: real, dockerExit: 0), 0)
        XCTAssertTrue(fm.fileExists(atPath: real.appendingPathComponent("data").path))
    }

    func testASymlinkedParentFolderIsFineAndGuardFailuresSaySo() throws {
        let fm = FileManager.default
        let root = realTemporaryDirectory().appendingPathComponent("rk-del-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // /opt-style layout: <root>/link is a symlink to <root>/real, and the stack is addressed through the link.
        let real = root.appendingPathComponent("real/stacks/app")
        try fm.createDirectory(at: real.appendingPathComponent("data"), withIntermediateDirectories: true)
        try "services: {}".write(to: real.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        let viaLink = root.appendingPathComponent("link/stacks/app")
        let ok = try runCapturing(StackRemoval(deleteFolder: true), dir: viaLink, dockerExit: 0)
        XCTAssertEqual(ok.code, 0, ok.out)
        XCTAssertFalse(fm.fileExists(atPath: real.path), "deleted through the symlinked parent")
        XCTAssertTrue(fm.fileExists(atPath: real.deletingLastPathComponent().path), "the parent is untouched")

        // A guard that fails says why instead of exiting silently, and deletes nothing.
        let bare = root.appendingPathComponent("real/stacks/bare")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        let missing = try runCapturing(StackRemoval(deleteFolder: true), dir: bare, dockerExit: 0)
        XCTAssertEqual(missing.code, 6)
        XCTAssertTrue(missing.out.contains("its compose file is missing"), missing.out)
        XCTAssertTrue(fm.fileExists(atPath: bare.path))

        // The folder itself being a symlink is reported as that, not as a file problem.
        let target = root.appendingPathComponent("real/stacks/target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "services: {}".write(to: target.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let linked = root.appendingPathComponent("real/stacks/linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: target)
        let symlink = try runCapturing(StackRemoval(deleteFolder: true), dir: linked, dockerExit: 0)
        XCTAssertEqual(symlink.code, 6)
        XCTAssertTrue(symlink.out.contains("it is a symbolic link"), symlink.out)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("compose.yaml").path))

        // A compose file that really lives elsewhere is reported as that.
        let outside = root.appendingPathComponent("real/stacks/outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere.yaml")
        try "services: {}".write(to: elsewhere, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: outside.appendingPathComponent("compose.yaml"), withDestinationURL: elsewhere)
        let notInside = try runCapturing(StackRemoval(deleteFolder: true), dir: outside, dockerExit: 0)
        XCTAssertEqual(notInside.code, 6)
        XCTAssertTrue(notInside.out.contains("not inside it"), notInside.out)
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))
    }
}
