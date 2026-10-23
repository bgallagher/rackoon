import Foundation
import Observation
import RackoonCore

/// One copy in the transfer list.
@MainActor @Observable
final class FileTransfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }

    nonisolated let id = UUID()
    let name: String
    let direction: Direction
    /// The server folder (upload) or the file on this device (download).
    let destination: String
    /// Where a finished download is on this device, to share or open.
    let localURL: URL?
    private(set) var bytes: Int64 = 0
    /// Nil while unknown (a folder coming down): the bar then shows bytes only.
    private(set) var total: Int64?
    private(set) var state: State = .waiting
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate let work: (FileTransfer) async throws -> Void

    init(name: String, direction: Direction, destination: String, localURL: URL? = nil, total: Int64?,
         work: @escaping (FileTransfer) async throws -> Void) {
        self.name = name; self.direction = direction; self.destination = destination; self.localURL = localURL
        self.total = total; self.work = work
    }

    var isFinished: Bool { if case .running = state { false } else if case .waiting = state { false } else { true } }
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } }
    /// Updates arrive as separate tasks, so they can come late or out of order: only ever move forward, and never after the end.
    func setProgress(_ b: Int64) { if !isFinished, b > bytes { bytes = b } }
    fileprivate func set(_ s: State) { state = s }
    func cancel() { task?.cancel(); if state == .waiting { state = .cancelled } }
}

/// Names that already exist where something is being uploaded: replace them, keep both, or skip them.
struct FileConflict: Identifiable {
    let id = UUID()
    let names: [String]
    let resolve: (Resolution) -> Void
    enum Resolution { case replace, keepBoth, skipExisting }
}

/// A question with one text field (a folder name, a new name).
struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let initial: String
    let action: String
    /// Why the typed name can't be used, or nil.
    let problem: (String) -> String?
    /// The command that will run for this name, shown under the field.
    let command: (String) -> String?
    let run: (String) -> Void
}

/// What the delete sheet shows. `plan.problems` non-empty means nothing can be deleted.
struct DeletePrompt: Identifiable {
    let id = UUID()
    let directory: String
    let names: [String]
    let plan: DeletePlan
    let run: () -> Void
}

/// The Files screen of one server on a phone: the server's folders (starting in the ssh user's home), uploads from the
/// Files app or Photos' files (a file or a whole folder), downloads into Rackoon's own Downloads folder (visible in the
/// Files app under On My iPhone), and new folder, rename and delete. Every change asks first with its exact command and
/// is refused in Read-only mode. Copies run one at a time, in order; a cancelled or cut-off upload leaves no half file
/// on the server, and a cancelled download leaves nothing under the real name here.
@MainActor @Observable
final class FilesModel {
    let server: Server
    private(set) var path = ""
    private(set) var listing: RemoteListing?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var transfers: [FileTransfer] = []
    var conflict: FileConflict?
    var pending: PendingAction?
    var namePrompt: NamePrompt?
    var deletePrompt: DeletePrompt?
    /// Why something could not start (read-only, a bad name...).
    var notice: String?
    /// Measuring folders before the confirm sheet can show.
    private(set) var preparing = false
    /// Where downloads go: Documents/Downloads/<server name>.
    let downloads: URL

    @ObservationIgnored private let session: FilesSession
    @ObservationIgnored private let safety: SafetyStore
    @ObservationIgnored private var started = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0

    init(server: Server, transport: SSHTransport, transfers: FileTransferring, safety: SafetyStore, downloads: URL) {
        self.server = server
        self.safety = safety
        self.downloads = downloads
        session = FilesSession(transport: transport, transfers: transfers, policy: safety.policy)
    }

    /// The first time the screen shows: the ssh user's home.
    func start() async {
        guard !started else { return }
        started = true
        let home = await session.homeDirectory() ?? "/"
        if path.isEmpty { await open(home) }
    }

    func open(_ target: String) async {
        loadToken += 1
        let token = loadToken
        loading = true
        defer { if token == loadToken { loading = false } }
        do {
            let result = try await session.list(target)
            guard token == loadToken else { return }
            listing = result
            path = result.path
            error = nil
        } catch {
            guard token == loadToken else { return }
            // Stay where we were; say why the folder could not be opened.
            if path.isEmpty { path = target }
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func reload() async { await open(path.isEmpty ? "/" : path) }

    var parent: String? { RemotePath.parent(of: path) }

    /// Folders first, then by name as Finder sorts; hidden names only when asked.
    func rows(showHidden: Bool) -> [FolderEntry] {
        (listing?.entries ?? [])
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    var hasFinished: Bool { transfers.contains(where: \.isFinished) }
    func clearFinished() { transfers.removeAll(where: \.isFinished) }

    private var changesBlocked: String? { safety.readOnly ? "Read-only mode is on" : nil }

    // MARK: upload (this device -> server)

    /// Files or folders picked in the Files app. They are security-scoped: access is taken while measuring and again
    /// while sending.
    func upload(urls: [URL]) {
        notice = nil
        if let why = changesBlocked { notice = why; return }
        guard !urls.isEmpty else { return }
        if preparing || pending != nil || conflict != nil { notice = "Finish the current upload first."; return }
        let existing = Set(listing?.entries.map(\.name) ?? [])
        let names = urls.map(\.lastPathComponent)
        let clashes = names.filter(existing.contains).sorted()
        let destination = path
        let go: (FileConflict.Resolution?) -> Void = { [self] resolution in
            var plan: [(url: URL, target: String)] = []
            for url in urls {
                let name = url.lastPathComponent
                if existing.contains(name) {
                    switch resolution {
                    case .replace?: plan.append((url, name))
                    case .keepBoth?: plan.append((url, RemoteFileNames.copyName(name, avoiding: existing.union(plan.map(\.target)))))
                    default: break
                    }
                } else {
                    plan.append((url, name))
                }
            }
            confirmUpload(plan, to: destination, replacing: resolution == .replace ? Set(clashes) : [])
        }
        if clashes.isEmpty { go(nil) } else { conflict = FileConflict(names: clashes, resolve: { go($0) }) }
    }

    private func confirmUpload(_ plan: [(url: URL, target: String)], to directory: String, replacing: Set<String>) {
        guard !plan.isEmpty else { return }
        let session = session
        preparing = true
        Task { [weak self] in
            guard let self else { return }
            defer { preparing = false }
            var jobs: [(url: URL, target: String, source: LocalSource, intent: Intent)] = []
            for (url, target) in plan {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let source: LocalSource
                do {
                    source = try await Task.detached { try Self.measure(url) }.value
                } catch {
                    notice = "“\(url.lastPathComponent)” can't be read: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    return
                }
                guard let intent = session.uploadIntent(source, toDirectory: directory, as: target) else {
                    notice = "“\(url.lastPathComponent)” has a character in its name that can't be sent safely."
                    return
                }
                jobs.append((url, target, source, intent))
            }
            let lines = jobs.map { job in
                let name = job.url.lastPathComponent, folder = { if case .folder = job.source { true } else { false } }()
                return "• \(name)\(job.target == name ? "" : " as \(job.target)") → \(directory)"
                    + (replacing.contains(name) ? (folder ? "  (merges into the existing folder)" : "  (replaces the existing file)") : "")
            }
            pending = PendingAction(
                title: "Upload \(jobs.count == 1 ? "“\(jobs[0].url.lastPathComponent)”" : "\(jobs.count) items") to \(server.name)?",
                message: "Copies from this device to \(directory) on \(server.name). Files are written under a temporary name first and moved into place only when complete, so a failed or cancelled upload leaves no half file.",
                serverName: server.name, command: jobs.map(\.intent.command).joined(separator: "\n"), destructive: !replacing.isEmpty,
                preview: lines.joined(separator: "\n"), confirmLabel: "Upload",
                run: { [weak self] in
                    guard let self else { return }
                    for job in jobs { self.enqueueUpload(job.url, source: job.source, target: job.target, intent: job.intent, directory: directory) }
                })
        }
    }

    /// A file's size, or a folder's archive size (the server checks the exact length of what arrives).
    nonisolated static func measure(_ url: URL) throws -> LocalSource {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            return .folder(url, bytes: TarWriter.size(of: try TarWriter.entries(of: url, as: url.lastPathComponent)))
        }
        return .file(url, bytes: Int64(values.fileSize ?? 0))
    }

    private func enqueueUpload(_ url: URL, source: LocalSource, target: String, intent: Intent, directory: String) {
        let session = session
        let transfer = FileTransfer(name: url.lastPathComponent, direction: .upload, destination: directory, total: source.bytes) { transfer in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let confirmation = try session.confirm(intent)
            try await session.upload(source, toDirectory: directory, as: target, confirmation: confirmation,
                                     progress: { b in Task { @MainActor in transfer.setProgress(b) } })
        }
        add(transfer, reloadFolder: directory)
    }

    // MARK: download (server -> this device)

    /// Copies an item into Downloads/<server>. An item of the same name there is kept: the copy gets a new name.
    func download(_ entry: FolderEntry) {
        notice = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            notice = "Couldn't make the Downloads folder: \(error.localizedDescription)"
            return
        }
        let taken = Set((try? fm.contentsOfDirectory(atPath: downloads.path)) ?? []).union(transfers.filter { !$0.isFinished }.compactMap { $0.localURL?.lastPathComponent })
        let target = taken.contains(entry.name) ? RemoteFileNames.copyName(entry.name, avoiding: taken) : entry.name
        let directory = path, session = session, destination = downloads
        let isFolder = entry.isDirectory
        let local = destination.appendingPathComponent(target, isDirectory: isFolder)
        let transfer = FileTransfer(name: entry.name, direction: .download, destination: local.path, localURL: local,
                                    total: isFolder ? nil : entry.size) { transfer in
            try await session.download(name: entry.name, isDirectory: isFolder, from: directory, toLocalDirectory: destination,
                                       as: target, replacing: false, progress: { b in Task { @MainActor in transfer.setProgress(b) } })
        }
        add(transfer, reloadFolder: nil)
    }

    // MARK: new folder, rename, delete

    func newFolder() {
        notice = nil
        if let why = changesBlocked { notice = why; return }
        let directory = path, taken = Set(listing?.entries.map(\.name) ?? [])
        namePrompt = NamePrompt(
            title: "New Folder", message: "In \(directory) on \(server.name)", initial: "", action: "Create",
            problem: { RemoteFileNames.problem($0, taken: taken) },
            command: { FileOperationCommands.command(for: .makeFolder(in: directory, name: $0.trimmingCharacters(in: .whitespaces))) },
            run: { [self] name in change(.makeFolder(in: directory, name: name.trimmingCharacters(in: .whitespaces))) })
    }

    func rename(_ entry: FolderEntry) {
        notice = nil
        if let why = changesBlocked { notice = why; return }
        let directory = path, name = entry.name
        let taken = Set(listing?.entries.map(\.name) ?? []).subtracting([name])
        namePrompt = NamePrompt(
            title: "Rename “\(name)”", message: "In \(directory) on \(server.name)", initial: name, action: "Rename",
            problem: { new in new == name ? "That is the current name" : RemoteFileNames.problem(new, taken: taken) },
            command: { FileOperationCommands.command(for: .rename(in: directory, from: name, to: $0.trimmingCharacters(in: .whitespaces))) },
            run: { [self] new in change(.rename(in: directory, from: name, to: new.trimmingCharacters(in: .whitespaces))) })
    }

    func delete(_ entries: [FolderEntry]) {
        notice = nil
        if let why = changesBlocked { notice = why; return }
        guard !entries.isEmpty else { return }
        let directory = path
        // A link to a folder is deleted as a link, never followed.
        let plan = DeletePlan(directory: directory, items: entries.map { ($0.name, $0.kind == .directory) })
        deletePrompt = DeletePrompt(directory: directory, names: entries.map(\.name), plan: plan, run: { [self] in
            Task {
                for op in plan.operations {
                    guard await perform(op) else { break }
                }
                await reload()
            }
        })
    }

    private func change(_ op: FileOperation) {
        Task {
            _ = await perform(op)
            await reload()
        }
    }

    /// Runs one confirmed change; says why on failure.
    private func perform(_ op: FileOperation) async -> Bool {
        do {
            guard let intent = session.intent(for: op) else { notice = "That change can't be made safely from here."; return false }
            try await session.perform(op, confirmation: try session.confirm(intent))
            return true
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
    }

    // MARK: the queue

    private func add(_ transfer: FileTransfer, reloadFolder folder: String?) {
        transfers.append(transfer)
        let previous = worker
        worker = Task { [weak self] in
            await previous?.value
            guard let self, transfer.state == .waiting else { return }
            transfer.set(.running)
            let job = Task { @MainActor in
                do {
                    try await transfer.work(transfer)
                    transfer.set(.done)
                } catch is CancellationError {
                    transfer.set(.cancelled)
                } catch {
                    transfer.set(Task.isCancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
            }
            transfer.task = job
            await job.value
            if let folder, self.path == folder { await self.reload() }
        }
    }

    /// Stops everything (the server was removed or its connection changed).
    func stop() {
        for transfer in transfers where !transfer.isFinished { transfer.cancel() }
    }
}
