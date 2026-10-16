import Foundation
import RackoonCore
import RackoonDemo
import RackoonSSHSystem

/// Demo mode: `RACKOON_DEMO=1 swift run RackoonMac` runs the whole app against made-up servers, for screenshots and
/// trying the app out. Nothing is sent to any real server and nothing real is read or saved: the servers live in a temporary
/// folder, favicons are cached in a temporary folder, and the terminal is a scripted fake shell that never runs what you type.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["RACKOON_DEMO"] != nil

    static let servers: [Server] = DemoFleet.servers

    private static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-demo-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var favicons: URL { directory.appendingPathComponent("favicons", isDirectory: true) }
    static var appIcons: URL { directory.appendingPathComponent("app-icons", isDirectory: true) }
    static var serviceSettings: URL { directory.appendingPathComponent("services", isDirectory: true) }
    static var alertSettings: URL { directory.appendingPathComponent("alerts", isDirectory: true) }

    /// A store holding just the demo servers, in a temporary folder (never the real `servers.json`).
    static func store() -> ServerStore {
        let store = ServerStore(directory: directory.appendingPathComponent("store", isDirectory: true))
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? store.saveServers(servers)
        return store
    }

    static func transport(for server: Server) -> SSHTransport { DemoFleet.transport(for: server) }

    /// The fake shell a terminal tab runs in demo mode: it prints a login banner and answers a few commands with canned text.
    static func terminalScript() -> URL {
        let url = directory.appendingPathComponent("demo-shell.sh")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? DemoFleet.shellScript.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

/// The transport every screen uses: the real ssh one, or the demo one in demo mode.
func makeTransport(for server: Server) -> SSHTransport {
    Demo.isOn ? Demo.transport(for: server) : OpenSSHTransport(server: server)
}
