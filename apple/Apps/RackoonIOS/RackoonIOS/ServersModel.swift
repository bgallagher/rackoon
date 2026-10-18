import Foundation
import Observation
import RackoonCore

/// The saved servers: Core's `ServerStore` (servers.json in the app's Application Support folder, or a temporary folder
/// in demo mode), with the same input checks as the Mac's Add and Edit forms.
@MainActor @Observable
final class ServersModel {
    private(set) var servers: [Server]
    /// Why the last save failed, shown in the list.
    var saveError: String?
    @ObservationIgnored let store: ServerStore

    init(store: ServerStore) {
        self.store = store
        servers = store.loadServers()
    }

    /// What the form typed, checked like the Mac's (there is no key file on iOS yet: keys arrive in stage I2).
    struct Draft: Equatable {
        var name = ""
        var host = ""
        var user = ""
        var port = ""

        init() {}

        init(_ server: Server) {
            name = server.name
            host = server.host
            user = server.user ?? ""
            port = server.port.map(String.init) ?? ""
        }

        var problem: String? { ServerInput.problem(host: host, user: user, port: port, identityFile: "") }

        func applied(to server: Server?) -> Server {
            let h = host.trimmingCharacters(in: .whitespaces)
            let u = user.trimmingCharacters(in: .whitespaces)
            let p = Int(port.trimmingCharacters(in: .whitespaces))
            let n = name.trimmingCharacters(in: .whitespaces)
            var s = server ?? Server(name: "", host: "")
            s.name = n.isEmpty ? h : n
            s.host = h
            s.user = u.isEmpty ? nil : u
            s.port = p == 22 ? nil : p
            return s
        }
    }

    func server(id: String) -> Server? { servers.first { $0.id == id } }

    func filtered(_ query: String) -> [Server] { ServerList.filter(servers, query: query) }

    /// Adds a server, or returns why it can't be saved.
    @discardableResult
    func add(_ draft: Draft, id: String = UUID().uuidString) -> String? {
        if let problem = draft.problem { return problem }
        servers.append(draft.applied(to: Server(id: id, name: "", host: "")))
        save()
        return nil
    }

    /// Saves an edit. Returns the problem, or nil; `connectionChanged` says whether the trusted host key must be checked again.
    @discardableResult
    func update(id: String, with draft: Draft) -> (problem: String?, connectionChanged: Bool) {
        if let problem = draft.problem { return (problem, false) }
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return ("That server no longer exists.", false) }
        let old = servers[index]
        let new = draft.applied(to: old)
        servers[index] = new
        save()
        return (nil, !old.connectsLike(new))
    }

    func remove(id: String) {
        servers.removeAll { $0.id == id }
        store.deleteSnapshot(serverID: id)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = servers
        let moving = source.map { list[$0] }
        for index in source.sorted(by: >) { list.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: destination - before)
        servers = list
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try store.saveServers(servers)
            saveError = nil
        } catch {
            saveError = "Could not save the server list: \(error.localizedDescription)"
        }
    }
}
