import Foundation

// A small tar writer and a streaming tar reader, for platforms that have no `tar` program to run (iOS). Folder uploads
// send `<name>/...` as a tar stream on the remote command's stdin (spec `files_upload_folder`, unpacked by GNU tar on the
// server), and folder downloads read the stream `tar -cf - .` writes (spec `files_download_folder`).
//
// The writer emits plain ustar headers, plus GNU `././@LongLink` records for names and link targets over 100 bytes (GNU
// tar and bsdtar both read them). Its size is known before anything is read, because the upload command refuses a stream
// of any other length. The reader understands what GNU tar and bsdtar write: ustar, GNU long names (`L`/`K`), pax
// headers (`x`, path/linkpath/size) and base-256 sizes. It never writes outside its folder: absolute paths and `..` are
// refused, and an entry below a link it created is refused (a link could otherwise point anywhere).

public enum TarError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case unsafePath(String)
    case changedWhileSending(String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): "The archive could not be read: \(why)."
        case .unsafePath(let path): "The archive holds “\(path)”, which would land outside the folder, so nothing more was unpacked."
        case .changedWhileSending(let path): "“\(path)” changed while it was being sent, so the upload was stopped."
        case .truncated: "The archive ended early."
        }
    }
}

/// One item of a folder to send.
public struct TarEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory, symlink(String) }
    /// The path inside the archive, `/`-separated, without a trailing slash (`photos/2024/a.jpg`).
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var mode: Int
    public var modified: Date
    /// Where a file's bytes come from.
    public var source: URL?

    public init(path: String, kind: Kind, size: Int64 = 0, mode: Int = 0o644, modified: Date = Date(timeIntervalSince1970: 0), source: URL? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modified = modified
        self.source = source
    }
}

public enum TarWriter {
    static let block = 512

    /// Every item of `folder`, named `<name>/...`, folders before what they hold. Links are sent as links, never followed.
    public static func entries(of folder: URL, as name: String) throws -> [TarEntry] {
        let fm = FileManager.default
        var out: [TarEntry] = []
        func visit(_ url: URL, _ path: String) throws {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let modified = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
            switch type {
            case .typeDirectory?:
                out.append(TarEntry(path: path, kind: .directory, mode: mode, modified: modified))
                for child in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(child), path + "/" + child)
                }
            case .typeSymbolicLink?:
                out.append(TarEntry(path: path, kind: .symlink(try fm.destinationOfSymbolicLink(atPath: url.path)), mode: mode, modified: modified))
            case .typeRegular?:
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                out.append(TarEntry(path: path, kind: .file, size: size, mode: mode, modified: modified, source: url))
            default:
                break   // sockets, devices, fifos: nothing to send
            }
        }
        try visit(folder, name)
        return out
    }

    /// Exactly how many bytes `write` produces for these entries.
    public static func size(of entries: [TarEntry]) -> Int64 {
        var total: Int64 = 0
        for entry in entries {
            total += Int64(headers(for: entry).count)
            if entry.kind == .file { total += padded(entry.size) }
        }
        return total + Int64(2 * block)
    }

    /// Sends the archive in chunks of at most `chunkSize` bytes. A file whose length differs from its entry stops it.
    public static func write(_ entries: [TarEntry], chunkSize: Int = 64 * 1024, to sink: (Data) async throws -> Void) async throws {
        var pending = Data()
        func flush(_ force: Bool) async throws {
            while pending.count >= chunkSize || (force && !pending.isEmpty) {
                let n = min(chunkSize, pending.count)
                try await sink(pending.prefix(n))
                pending = Data(pending.dropFirst(n))
            }
        }
        for entry in entries {
            try Task.checkCancellation()
            pending.append(headers(for: entry))
            try await flush(false)
            guard entry.kind == .file, let source = entry.source else { continue }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var sent: Int64 = 0
            while true {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                if data.isEmpty { break }
                sent += Int64(data.count)
                guard sent <= entry.size else { throw TarError.changedWhileSending(entry.path) }
                pending.append(data)
                try await flush(false)
            }
            guard sent == entry.size else { throw TarError.changedWhileSending(entry.path) }
            pending.append(Data(count: Int(padded(entry.size) - entry.size)))
        }
        pending.append(Data(count: 2 * block))
        try await flush(true)
    }

    static func padded(_ size: Int64) -> Int64 { (size + Int64(block) - 1) / Int64(block) * Int64(block) }

    /// The header block(s) for one entry: GNU long-name records first when the name or link target needs them.
    static func headers(for entry: TarEntry) -> Data {
        var out = Data()
        let name = entry.kind == .directory ? entry.path + "/" : entry.path
        var link = ""
        if case .symlink(let target) = entry.kind { link = target }
        if link.utf8.count > 100 { out.append(longRecord(link, type: "K")) }
        if name.utf8.count > 100 { out.append(longRecord(name, type: "L")) }
        let type: UInt8 = switch entry.kind {
        case .file: UInt8(ascii: "0")
        case .directory: UInt8(ascii: "5")
        case .symlink: UInt8(ascii: "2")
        }
        out.append(header(name: name, mode: entry.mode & 0o7777, size: entry.kind == .file ? entry.size : 0,
                          modified: Int64(entry.modified.timeIntervalSince1970), type: type, link: link))
        return out
    }

    /// A `././@LongLink` record carrying a name that does not fit the 100-byte field.
    static func longRecord(_ text: String, type: Character) -> Data {
        let bytes = Data(text.utf8) + Data([0])
        var out = header(name: "././@LongLink", mode: 0o644, size: Int64(bytes.count), modified: 0, type: type.asciiValue!, link: "")
        out.append(bytes)
        out.append(Data(count: Int(padded(Int64(bytes.count))) - bytes.count))
        return out
    }

    static func header(name: String, mode: Int, size: Int64, modified: Int64, type: UInt8, link: String) -> Data {
        var h = [UInt8](repeating: 0, count: block)
        func put(_ bytes: some Collection<UInt8>, at offset: Int, max: Int) {
            for (i, b) in bytes.prefix(max).enumerated() { h[offset + i] = b }
        }
        func octal(_ value: Int64, at offset: Int, width: Int) {
            let digits = String(value, radix: 8)
            if digits.count <= width - 1 {
                put(Array((String(repeating: "0", count: width - 1 - digits.count) + digits).utf8), at: offset, max: width - 1)
            } else {
                // Too big for octal (files over 8 GiB): GNU base-256, the high bit marks it.
                var v = value
                for i in stride(from: width - 1, through: 1, by: -1) { h[offset + i] = UInt8(v & 0xFF); v >>= 8 }
                h[offset] = 0x80
            }
        }
        put(Array(name.utf8), at: 0, max: 100)
        octal(Int64(mode), at: 100, width: 8)
        octal(0, at: 108, width: 8)            // uid: the server unpacks with --no-same-owner
        octal(0, at: 116, width: 8)            // gid
        octal(size, at: 124, width: 12)
        octal(max(0, modified), at: 136, width: 12)
        put(Array(repeating: UInt8(ascii: " "), count: 8), at: 148, max: 8)
        h[156] = type
        put(Array(link.utf8), at: 157, max: 100)
        put(Array("ustar".utf8), at: 257, max: 6)
        put(Array("00".utf8), at: 263, max: 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(Array((String(repeating: "0", count: max(0, 6 - String(sum, radix: 8).count)) + String(sum, radix: 8)).utf8), at: 148, max: 6)
        h[154] = 0
        h[155] = UInt8(ascii: " ")
        return Data(h)
    }
}

/// Unpacks a tar stream into a folder as it arrives. Feed it chunks in order, then call `finish`.
public final class TarExtractor {
    public let folder: URL
    /// Entries that were not unpacked (hard links, devices), by archive path.
    public private(set) var skipped: [String] = []

    private enum State {
        case header
        case file(FileHandle?, remaining: Int64, padding: Int64)
        case skip(remaining: Int64)
        case longName(type: UInt8, remaining: Int64, padding: Int64, collected: Data)
        case pax(remaining: Int64, padding: Int64, collected: Data, global: Bool)
        case ended
    }

    private var state = State.header
    private var buffer = Data()
    private var zeroBlocks = 0
    private var longName: String?
    private var longLink: String?
    private var paxPath: String?
    private var paxLink: String?
    private var paxSize: Int64?
    private var links: Set<String> = []
    private var pendingAttributes: [(URL, Int, Date)] = []

    public init(into folder: URL) { self.folder = folder }

    public func feed(_ data: Data) throws {
        buffer.append(data)
        while try step() {}
    }

    /// Ends the stream: anything but a complete archive is an error. Folder dates and modes are set last, since writing
    /// into a folder changes its date.
    public func finish() throws {
        switch state {
        case .ended: break
        case .header where buffer.isEmpty && zeroBlocks > 0: break   // one end block is enough (some writers stop there)
        default:
            if case .file(let handle, _, _) = state { try? handle?.close() }
            throw TarError.truncated
        }
        for (url, mode, date) in pendingAttributes.reversed() {
            try? FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// Consumes what it can from the buffer; false when it needs more data.
    private func step() throws -> Bool {
        switch state {
        case .ended:
            buffer.removeAll()
            return false
        case .header:
            guard buffer.count >= TarWriter.block else { return false }
            let block = Data(buffer.prefix(TarWriter.block))
            buffer = Data(buffer.dropFirst(TarWriter.block))
            try header(block)
            return true
        case .file(let handle, let remaining, let padding):
            if remaining > 0 {
                guard !buffer.isEmpty else { return false }
                let n = Int(min(remaining, Int64(buffer.count)))
                try handle?.write(contentsOf: buffer.prefix(n))
                buffer = Data(buffer.dropFirst(n))
                state = .file(handle, remaining: remaining - Int64(n), padding: padding)
                return true
            }
            try handle?.close()
            state = .skip(remaining: padding)
            return true
        case .skip(let remaining):
            if remaining == 0 { state = .header; return true }
            guard !buffer.isEmpty else { return false }
            let n = Int(min(remaining, Int64(buffer.count)))
            buffer = Data(buffer.dropFirst(n))
            state = .skip(remaining: remaining - Int64(n))
            return true
        case .longName(let type, let remaining, let padding, var collected):
            if remaining > 0 {
                guard !buffer.isEmpty else { return false }
                let n = Int(min(remaining, Int64(buffer.count)))
                collected.append(buffer.prefix(n))
                buffer = Data(buffer.dropFirst(n))
                state = .longName(type: type, remaining: remaining - Int64(n), padding: padding, collected: collected)
                return true
            }
            let text = Self.string(collected)
            if type == UInt8(ascii: "K") { longLink = text } else { longName = text }
            state = .skip(remaining: padding)
            return true
        case .pax(let remaining, let padding, var collected, let global):
            if remaining > 0 {
                guard !buffer.isEmpty else { return false }
                let n = Int(min(remaining, Int64(buffer.count)))
                collected.append(buffer.prefix(n))
                buffer = Data(buffer.dropFirst(n))
                state = .pax(remaining: remaining - Int64(n), padding: padding, collected: collected, global: global)
                return true
            }
            if !global { applyPax(collected) }
            state = .skip(remaining: padding)
            return true
        }
    }

    private func header(_ block: Data) throws {
        let h = [UInt8](block)
        if h.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { state = .ended }
            return
        }
        zeroBlocks = 0
        // The sum of the header's bytes with the checksum field read as spaces (old writers summed signed bytes).
        let unsigned = h.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
        let signed = h.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int(Int8(bitPattern: $1.element))) }
        guard let expected = Self.number(h[148..<156]).map(Int.init), expected == unsigned || expected == signed else {
            throw TarError.unreadable("a header's checksum does not match")
        }
        let type = h[156]
        guard var size = Self.number(h[124..<136]) else { throw TarError.unreadable("a header's size is not a number") }
        if let paxSize, type != UInt8(ascii: "x"), type != UInt8(ascii: "g") { size = paxSize }
        let padding = TarWriter.padded(size) - size
        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "K"):
            state = .longName(type: type, remaining: size, padding: padding, collected: Data())
            return
        case UInt8(ascii: "x"), UInt8(ascii: "g"):
            state = .pax(remaining: size, padding: padding, collected: Data(), global: type == UInt8(ascii: "g"))
            return
        default:
            break
        }
        var name = Self.string(Data(h[0..<100]))
        let prefix = Self.string(Data(h[345..<500]))
        if Self.string(Data(h[257..<262])) == "ustar", !prefix.isEmpty { name = prefix + "/" + name }
        name = paxPath ?? longName ?? name
        let link = paxLink ?? longLink ?? Self.string(Data(h[157..<257]))
        let mode = Int(Self.number(h[100..<108]) ?? 0o644) & 0o7777
        let modified = Date(timeIntervalSince1970: TimeInterval(Self.number(h[136..<148]) ?? 0))
        longName = nil; longLink = nil; paxPath = nil; paxLink = nil; paxSize = nil

        guard let relative = try safePath(name) else {
            state = .skip(remaining: size + padding)   // `.` itself: the folder exists already
            return
        }
        let url = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
        let fm = FileManager.default
        switch type {
        case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
            try removeLink(at: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw TarError.unreadable("“\(relative)” could not be created") }
            let handle = try FileHandle(forWritingTo: url)
            pendingAttributes.append((url, mode, modified))
            state = .file(handle, remaining: size, padding: padding)
        case UInt8(ascii: "5"):
            try removeLink(at: relative)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            pendingAttributes.append((url, mode, modified))
            state = .skip(remaining: size + padding)
        case UInt8(ascii: "2"):
            try removeLink(at: relative)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: link)
            links.insert(relative)
            state = .skip(remaining: size + padding)
        default:
            // Hard links, devices, fifos: not unpacked.
            skipped.append(relative)
            state = .skip(remaining: size + padding)
        }
    }

    /// The path inside the folder, "" for the folder itself, nil for `.`; throws for anything that would leave it.
    private func safePath(_ raw: String) throws -> String? {
        if raw.hasPrefix("/") { throw TarError.unsafePath(raw) }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.contains("..") { throw TarError.unsafePath(raw) }
        if parts.isEmpty { return nil }
        let path = parts.joined(separator: "/")
        // Below a link it made: the link could point anywhere.
        for i in 1..<parts.count where links.contains(parts[..<i].joined(separator: "/")) { throw TarError.unsafePath(raw) }
        return path
    }

    /// An entry replacing a link this archive made: remove the link itself, never write through it.
    private func removeLink(at relative: String) throws {
        guard links.remove(relative) != nil else { return }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(relative))
    }

    private func applyPax(_ data: Data) {
        // Records are "<length> <key>=<value>\n", the length counting the whole record.
        var rest = [UInt8](data)[...]
        while let space = rest.firstIndex(of: UInt8(ascii: " ")),
              let length = Int(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)), length > 0, length <= rest.count {
            var body = rest[(space + 1)..<(rest.startIndex + length)]
            if body.last == UInt8(ascii: "\n") { body = body.dropLast() }
            if let eq = body.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: body[body.startIndex..<eq], as: UTF8.self)
                let value = String(decoding: body[(eq + 1)...], as: UTF8.self)
                switch key {
                case "path": paxPath = value
                case "linkpath": paxLink = value
                case "size": paxSize = Int64(value)
                default: break
                }
            }
            rest = rest.dropFirst(length)
        }
    }

    static func string(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// An octal field (spaces and NULs around it ignored) or a GNU base-256 one.
    static func number(_ bytes: ArraySlice<UInt8>) -> Int64? {
        guard let first = bytes.first else { return nil }
        if first & 0x80 != 0 {
            var v = Int64(first & 0x7F)
            for b in bytes.dropFirst() { v = v << 8 | Int64(b) }
            return v
        }
        let text = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        return Int64(text, radix: 8)
    }
}
