import CryptoKit
import Foundation
import Observation
import RackoonCore
import UIKit

/// Logos for Docker apps and their services, as on the Mac (`AppIconStore` there): the dashboard-icons collection
/// (Apache-2.0) and, for apps it lacks, selfh.st icons (CC BY 4.0), both from jsDelivr; Unraid template icon URLs; and images
/// the user picked on this device. Cached under Application Support/Rackoon/app-icons. `AppIconGuess` (Core) picks the
/// automatic icon and `IconChoices` (Core) keeps the user's choices, on this device only (nothing is written to the server).
/// Only icon names and template URLs are requested, never anything about the server; normal certificate checks apply.
@MainActor @Observable
final class AppIconStore {
    private(set) var catalog: IconCatalog?
    /// Icon id -> image, for icons fetched or imported this run (observed, so views redraw when one arrives).
    private(set) var images: [String: UIImage] = [:]
    private(set) var queue = IconFetchQueue()
    private(set) var choices = IconChoices()
    /// The user's own images, newest first (ids `custom:<hex>`).
    private(set) var customIcons: [String] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let network: Bool
    @ObservationIgnored private var dashboardNames: [String] = []
    @ObservationIgnored private var selfhstNames: [String] = []
    @ObservationIgnored private var diskCache: [String: UIImage] = [:]
    @ObservationIgnored private var catalogTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogTriedAt: Date?
    @ObservationIgnored private var workers = 0
    nonisolated private static let maxWorkers = 6
    private static let catalogMaxAge: TimeInterval = 7 * 24 * 3600
    nonisolated static let maxImportBytes = 8 * 1024 * 1024

    private var catalogFile: URL { directory.appendingPathComponent("catalog.json") }
    private var selfhstFile: URL { directory.appendingPathComponent("selfhst-index.json") }
    private var choicesFile: URL { directory.appendingPathComponent("choices.json") }
    private var customDirectory: URL { directory.appendingPathComponent("custom", isDirectory: true) }

    /// `network: false` (tests) never downloads anything.
    init(directory: URL, network: Bool = true) {
        self.directory = directory
        self.network = network
        for folder in ["icons", "icons-selfhst", "icons-linked", "custom"] {
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: catalogFile), let parsed = IconCatalog.parseTree(data) { dashboardNames = Array(parsed.names) }
        if let data = try? Data(contentsOf: selfhstFile), let parsed = IconCatalog.parseSelfhstIndex(data) { selfhstNames = parsed }
        rebuildCatalog()
        if let data = try? Data(contentsOf: choicesFile), let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            choices = IconChoices(loaded)
        }
        let custom = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        customIcons = custom.filter { $0.pathExtension == "png" }
            .sorted { Self.modified($0) > Self.modified($1) }
            .map { "custom:" + $0.deletingPathExtension().lastPathComponent }
            .filter { AppIconRef(id: $0) != nil }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func rebuildCatalog() {
        guard !dashboardNames.isEmpty || !selfhstNames.isEmpty else { return }
        catalog = IconCatalog(names: dashboardNames, selfhst: selfhstNames)
    }

    private func file(for ref: AppIconRef) -> URL {
        switch ref {
        case .dashboard(let name): directory.appendingPathComponent("icons/\(name).png")
        case .selfhst(let name): directory.appendingPathComponent("icons-selfhst/\(name).png")
        case .custom(let hex): customDirectory.appendingPathComponent("\(hex).png")
        case .remote(let url): directory.appendingPathComponent("icons-linked/\(Self.sha256(Data(url.utf8)).prefix(32)).png")
        }
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: choosing (the rules are Core's `IconChoices`)

    func stackIcon(_ stack: DockerStack, server: String) -> String? {
        choices.stackIcon(stack, server: server, catalog: catalog, failed: queue.hasFailed)
    }

    func prefersLetter(_ stack: DockerStack, server: String) -> Bool { choices.prefersLetter(stack, server: server) }

    func serviceIcon(_ container: DockerContainer, in stack: DockerStack, server: String) -> String? {
        choices.serviceIcon(container, in: stack, server: server, catalog: catalog, failed: queue.hasFailed)
    }

    func guessedStackIcon(_ stack: DockerStack) -> String? { AppIconGuess.iconID(for: stack, in: catalog) }
    func guessedServiceIcon(_ container: DockerContainer) -> String? { AppIconGuess.iconID(for: container, in: catalog) }

    func isChosen(_ stack: DockerStack, service: DockerContainer? = nil, server: String) -> Bool {
        choices.isChosen(stack, service: service, server: server)
    }

    /// `id`: an icon; "" for the letter (an app) or the app's icon (a service); nil to go back to the automatic choice.
    func choose(_ id: String?, for stack: DockerStack, service: DockerContainer? = nil, server: String) {
        guard choices.choose(id, for: stack, service: service, server: server) else { return }
        saveChoices()
        if let id, !id.isEmpty { ensure([id], urgent: true) }
    }

    /// A removed server's choices go with it (the user's own images stay, they may be used elsewhere).
    func forget(serverID: String) {
        if choices.forget(serverID: serverID) { saveChoices() }
    }

    private func saveChoices() {
        if let data = try? JSONEncoder().encode(choices.overrides) { try? data.write(to: choicesFile, options: .atomic) }
    }

    // MARK: the user's own images

    /// Redraws an image the user picked as a 256 px PNG and keeps it. Returns its id, or nil if it isn't an image UIKit
    /// can read (or is over 8 MB). The same picture imported twice is stored once.
    func importImage(_ raw: Data) async -> String? {
        guard raw.count <= Self.maxImportBytes else { return nil }
        let png = await Task.detached(priority: .userInitiated) { FaviconStore.renderPNG(raw, side: 256) }.value
        guard let png, let image = UIImage(data: png) else { return nil }
        let ref = AppIconRef.custom(String(Self.sha256(png).prefix(32)))
        try? png.write(to: file(for: ref), options: .atomic)
        images[ref.id] = image
        customIcons.removeAll { $0 == ref.id }
        customIcons.insert(ref.id, at: 0)
        return ref.id
    }

    /// Deletes one of the user's images, and every choice that used it (those go back to automatic).
    func deleteCustom(_ id: String) {
        guard let ref = AppIconRef(id: id), case .custom = ref else { return }
        try? FileManager.default.removeItem(at: file(for: ref))
        customIcons.removeAll { $0 == id }
        images[id] = nil
        diskCache[id] = nil
        if choices.removeUses(of: id) { saveChoices() }
    }

    // MARK: fetching

    func image(_ id: String) -> UIImage? {
        if let image = images[id] ?? diskCache[id] { return image }
        guard let ref = AppIconRef(id: id), let image = UIImage(contentsOfFile: file(for: ref).path) else { return nil }
        diskCache[id] = image
        return image
    }

    /// Downloads the name lists if there are none yet or they are over a week old (one try a minute at most).
    func ensureCatalog() {
        guard network, catalogTasks.isEmpty else { return }
        if let last = catalogTriedAt, Date().timeIntervalSince(last) < 60 { return }
        let lists: [(String, URL, String)] = [
            ("dashboard", catalogFile, "\(AppIconRef.dashboardCDN)/tree.json"),
            ("selfhst", selfhstFile, "\(AppIconRef.selfhstCDN)/index.json"),
        ]
        for (name, file, address) in lists {
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
            let loaded = name == "dashboard" ? !dashboardNames.isEmpty : !selfhstNames.isEmpty
            guard !loaded || (age ?? .infinity) > Self.catalogMaxAge else { continue }
            catalogTriedAt = Date()
            catalogTasks[name] = Task { [weak self] in
                let data = await Self.download(address, limit: 6 * 1024 * 1024)
                let names: [String]? = await Task.detached {
                    guard let data else { return nil }
                    return name == "dashboard" ? IconCatalog.parseTree(data).map { Array($0.names) } : IconCatalog.parseSelfhstIndex(data)
                }.value
                if let data, let names {
                    try? data.write(to: file, options: .atomic)
                    if name == "dashboard" { self?.dashboardNames = names } else { self?.selfhstNames = names }
                    self?.rebuildCatalog()
                }
                self?.catalogTasks[name] = nil
            }
        }
    }

    /// Fetches icons that are not on disk yet (`IconFetchQueue` decides which and in what order).
    func ensure(_ ids: [String], urgent: Bool = false) {
        guard network else { return }
        queue.request(ids, urgent: urgent) { id in
            guard let ref = AppIconRef(id: id) else { return true }
            return images[id] != nil || diskCache[id] != nil || FileManager.default.fileExists(atPath: file(for: ref).path)
        }
        while workers < Self.maxWorkers, !queue.waiting.isEmpty {
            workers += 1
            Task { [weak self] in
                while let self, let id = self.queue.next() {
                    guard let address = AppIconRef(id: id)?.downloadURL else { self.finish(id, nil); continue }
                    let png = await Self.fetchPNG(address, side: 256)
                    self.finish(id, png)
                }
                self?.workers -= 1
            }
        }
    }

    private func finish(_ id: String, _ png: Data?) {
        if let png, let ref = AppIconRef(id: id), let image = UIImage(data: png) {
            try? png.write(to: file(for: ref), options: .atomic)
            images[id] = image
            queue.finish(id, success: true)
        } else {
            queue.finish(id, success: false)
        }
    }

    nonisolated private static func fetchPNG(_ address: String, side: Int) async -> Data? {
        guard let data = await download(address, limit: 4 * 1024 * 1024) else { return nil }
        return FaviconStore.renderPNG(data, side: side)
    }

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = maxWorkers
        return URLSession(configuration: configuration)
    }()

    /// A plain GET with a size cap and no cookies or credentials. Nil on any error, a non-2xx answer or an oversized body.
    nonisolated private static func download(_ address: String, limit: Int) async -> Data? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Rackoon/1.0 (app icons)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= limit,
              let final = response.url?.scheme?.lowercased(), final == "http" || final == "https" else { return nil }
        return data
    }
}

/// Favicons of bookmarked services, fetched from this device (so Tailscale-only addresses work when it is on the tailnet),
/// cached as 128 px PNGs under Application Support/Rackoon/favicons. One icon per site (its origin), from the page's
/// `<link rel="icon">` tags (`FaviconLinks`, Core) and then `/favicon.ico`. A site with no icon is left alone for a day;
/// tapping an icon fetches a fresh one. Only a GET with no credentials is sent, so certificate errors (self-signed home
/// servers) are tolerated for this fetch; the worst a network attacker could do is swap the picture.
@MainActor @Observable
final class FaviconStore {
    private(set) var images: [String: UIImage] = [:]
    private(set) var fetching: Set<String> = []

    private struct Entry: Codable {
        var file: String?
        var attemptedAt: Date
    }

    @ObservationIgnored private var index: [String: Entry] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let network: Bool
    @ObservationIgnored private var queue: [(origin: String, href: String)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    private static let retryAfter: TimeInterval = 24 * 3600

    init(directory: URL, network: Bool = true) {
        self.directory = directory
        self.network = network
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = loaded
            for (origin, entry) in loaded {
                if let file = entry.file, let image = UIImage(contentsOfFile: directory.appendingPathComponent(file).path) { images[origin] = image }
            }
        }
    }

    func image(for href: String) -> UIImage? { FaviconLinks.origin(of: href).flatMap { images[$0] } }
    func isFetching(_ href: String) -> Bool { FaviconLinks.origin(of: href).map { fetching.contains($0) } ?? false }

    /// Fetches icons that are missing: sites never tried, and sites without an icon last tried over a day ago.
    func ensure(_ hrefs: [String]) {
        guard network else { return }
        for href in hrefs {
            guard let origin = FaviconLinks.origin(of: href), !fetching.contains(origin), !queue.contains(where: { $0.origin == origin }) else { continue }
            if let entry = index[origin], entry.file != nil || Date().timeIntervalSince(entry.attemptedAt) < Self.retryAfter { continue }
            enqueue(origin, href)
        }
    }

    /// The user tapped the icon: try again now, whatever was cached.
    func refresh(_ href: String) {
        guard network, let origin = FaviconLinks.origin(of: href), !fetching.contains(origin) else { return }
        enqueue(origin, href)
    }

    private func enqueue(_ origin: String, _ href: String) {
        queue.append((origin, href))
        fetching.insert(origin)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // One at a time, so a long bookmark list doesn't open dozens of connections at once.
            while let job = self?.queue.first {
                self?.queue.removeFirst()
                let png = await Self.fetchIcon(origin: job.origin, href: job.href)
                self?.finish(origin: job.origin, png: png)
            }
            self?.worker = nil
        }
    }

    private func finish(origin: String, png: Data?) {
        fetching.remove(origin)
        if let png, let image = UIImage(data: png) {
            let name = Self.fileName(for: origin)
            try? png.write(to: directory.appendingPathComponent(name), options: .atomic)
            images[origin] = image
            index[origin] = Entry(file: name, attemptedAt: Date())
        } else if index[origin]?.file == nil {
            index[origin] = Entry(file: nil, attemptedAt: Date())
        }
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
    }

    nonisolated private static func fileName(for origin: String) -> String {
        SHA256.hash(data: Data(origin.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    nonisolated private static func fetchIcon(origin: String, href: String) async -> Data? {
        var tried = Set<URL>()
        var urls: [URL] = []
        if let pageURL = URL(string: href), let page = await get(pageURL, limit: 256 * 1024),
           let html = String(data: page.data, encoding: .utf8) ?? String(data: page.data, encoding: .isoLatin1) {
            urls += FaviconLinks.candidates(in: html, base: page.finalURL).map(\.url)
        }
        if let fallback = FaviconLinks.defaultIcon(for: origin) { urls.append(fallback) }
        for url in urls where tried.insert(url).inserted {
            if let response = await get(url, limit: 1024 * 1024), let png = renderPNG(response.data, side: 128) { return png }
        }
        return nil
    }

    fileprivate struct Response { var data: Data; var finalURL: URL }

    /// A GET with a size cap: 2xx only, http(s) only (a redirect to anything else is refused); the transfer stops at `limit`.
    nonisolated private static func get(_ url: URL, limit: Int) async -> Response? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Rackoon/1.0 (favicon fetch)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let fetch = LimitedFetch(limit: limit, fallbackURL: url)
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetch.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Decodes whatever image format arrived (PNG, ICO, JPEG, GIF, WebP...) and redraws it as a square PNG.
    nonisolated static func renderPNG(_ data: Data, side: Int) -> Data? {
        guard let source = UIImage(data: data), source.size.width >= 1, source.size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scale = min(CGFloat(side) / source.size.width, CGFloat(side) / source.size.height)
        let w = source.size.width * scale, h = source.size.height * scale
        return renderer.pngData { _ in
            source.draw(in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        }
    }
}

/// One capped download that accepts any server certificate, for the favicon fetch only (no credentials or cookies are sent).
private final class LimitedFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    let fallbackURL: URL
    private var continuation: CheckedContinuation<FaviconStore.Response?, Never>?
    private var early: FaviconStore.Response??
    private let lock = NSLock()
    private var data = Data()
    private var accepted = false
    private var finalURL: URL?
    private var done = false

    init(limit: Int, fallbackURL: URL) {
        self.limit = limit
        self.fallbackURL = fallbackURL
    }

    func start(_ continuation: CheckedContinuation<FaviconStore.Response?, Never>) {
        let ready: FaviconStore.Response?? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            lock.withLock { accepted = true; finalURL = http.url }
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let full = lock.withLock { () -> Bool in
            data.append(chunk)
            return data.count >= limit
        }
        if full { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "http" || scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: FaviconStore.Response? = lock.withLock {
            guard !done else { return nil }
            done = true
            guard accepted, !data.isEmpty else { return nil }
            return FaviconStore.Response(data: data, finalURL: finalURL ?? fallbackURL)
        }
        let waiting: CheckedContinuation<FaviconStore.Response?, Never>? = lock.withLock {
            guard let c = continuation else { early = .some(result); return nil }
            continuation = nil
            return c
        }
        waiting?.resume(returning: result)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
