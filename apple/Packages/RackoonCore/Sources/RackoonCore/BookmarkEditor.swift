import Foundation

/// One bookmark found on a running container, with where it lives.
public struct BookmarkItem: Sendable, Equatable, Identifiable {
    public let stack: DockerStack
    public let container: DockerContainer
    public let bookmark: Bookmark

    public init(stack: DockerStack, container: DockerContainer, bookmark: Bookmark) {
        self.stack = stack
        self.container = container
        self.bookmark = bookmark
    }

    public var id: String { container.id }
    public var service: String { container.service ?? container.name }
    /// What the list shows: the bookmark's name, or the service's.
    public var title: String { bookmark.title(fallback: service) }

    /// Every bookmark on these stacks, in stack order.
    public static func items(in stacks: [DockerStack]) -> [BookmarkItem] {
        stacks.flatMap { stack in stack.containers.compactMap { c in c.bookmark.map { BookmarkItem(stack: stack, container: c, bookmark: $0) } } }
    }

    /// The `homepage.group` names in use, sorted ignoring case.
    public static func groups(in stacks: [DockerStack]) -> [String] {
        Array(Set(items(in: stacks).compactMap(\.bookmark.group))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Stacks a bookmark can be added to: compose stacks with at least one container and compose files we can edit.
    public static func bookmarkableStacks(_ stacks: [DockerStack]) -> [DockerStack] {
        stacks.filter { !$0.isStandalone && !$0.containers.isEmpty && StackFiles.editable(for: $0) != nil }
    }
}

extension DockerStack {
    /// The compose services of a stack that have a container, sorted.
    public var serviceNames: [String] { Array(Set(containers.compactMap(\.service))).sorted() }
}

/// What a bookmark edit found.
public enum BookmarkPlan: Sendable, Equatable {
    /// The labels are ready to be written: show the diff, then save the edit.
    case ready(FileEdit)
    /// Nothing to do, or it can't be done; in words for the user.
    case notice(String)
}

/// Reads the compose file that defines a service, edits its Homepage labels and returns the change for the user to
/// confirm. Nothing is written here. The same steps as `BookmarkModel.prepare` on the Mac and `BookmarkEditor` in Kotlin.
public enum BookmarkEditor {
    public static func plan(session: StackFileSession, stack: DockerStack, service: String,
                            changes: [(key: String, value: String?)], removing: Bool, serverName: String) async throws -> BookmarkPlan {
        var found: (file: EditableFile, remote: RemoteFile, text: String)?
        var unreadable: [String] = []
        // The first compose file that defines the service (an override file may be the one that does).
        for file in session.files where !file.isEnv {
            switch try await session.read(file) {
            case .file(let remote):
                guard ComposeLabels.definesService(service, in: remote.content) else { continue }
                do {
                    found = (file, remote, try ComposeLabels.setting(changes, onService: service, in: remote.content))
                } catch {
                    return .notice((error as? LocalizedError)?.errorDescription ?? "That file can't be edited automatically.")
                }
            case .missing: unreadable.append("\(file.fileName) is missing on \(serverName)")
            case .tooLarge: unreadable.append("\(file.fileName) is too large to edit here")
            }
            if found != nil { break }
        }
        guard let found else {
            // Say why when a file could not be read, instead of claiming the service doesn't exist.
            return .notice(unreadable.isEmpty ? "No compose file of \(stack.name) defines a service called \(service)."
                                              : "Couldn't read the stack's compose file: " + unreadable.joined(separator: "; ") + ".")
        }
        guard found.text != found.remote.content else {
            return .notice(removing ? "\(service) has no bookmark labels to remove." : "Nothing would change in \(found.file.fileName).")
        }
        return .ready(FileEdit(file: found.file, original: found.remote.content, originalSHA: found.remote.sha256, content: found.text))
    }

    /// A bare address like `app.example.com` is read as https.
    public static func normalizedURL(_ url: String) -> String {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.contains("://") ? t : "https://" + t
    }
}
