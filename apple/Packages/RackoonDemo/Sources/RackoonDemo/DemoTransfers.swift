import Foundation
import RackoonCore

/// File transfers in demo mode: progress moves, nothing is sent anywhere, and a download writes a small placeholder.
public struct DemoFileTransfers: FileTransferring {
    public init() {}

    public func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        for step in 1...10 {
            try await Task.sleep(nanoseconds: 120_000_000)
            progress(source.bytes * Int64(step) / 10)
        }
    }

    public func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        for step in 1...6 {
            try await Task.sleep(nanoseconds: 120_000_000)
            progress(Int64(step) * 40_000)
        }
        switch sink {
        case .file(let url): try Data("Demo file: nothing was downloaded.\n".utf8).write(to: url)
        case .folder(let into): try Data("Demo file.\n".utf8).write(to: into.appendingPathComponent("README.txt"))
        }
    }
}
