import Foundation
import NIOCore
@preconcurrency import NIOSSH
import RackoonCore

/// File transfers over the shared connection, like the Mac's `OpenSSHTransfers`: the bytes travel on a plain remote
/// command's stdin or stdout (spec `files_upload_*`, `files_download_*`), never sftp. Folders travel as tar streams that
/// Core's `TarWriter`/`TarExtractor` make and read here, because iOS has no tar program. Cancelling the calling task
/// closes the channel: an upload the server did not receive in full is refused by the upload command, and a download
/// the app did not receive in full is never moved into place (`FilesSession`).
extension EmbeddedSSHTransport: FileTransferring {
    static let chunkSize = 64 * 1024

    public func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (channel, events) = try await openSessionChannel()
        try await withTaskCancellationHandler {
            try await channel.request(SSHChannelRequestEvent.ExecRequest(command: remoteCommand, wantReply: false))
            async let outcome = Self.outcome(of: events)
            var sent: Int64 = 0
            do {
                switch source {
                case .file(let url, _):
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                        try await channel.send(data)
                        sent += Int64(data.count)
                        progress(sent)
                    }
                case .folder(let url, _):
                    let entries = try TarWriter.entries(of: url, as: url.lastPathComponent)
                    try await TarWriter.write(entries, chunkSize: Self.chunkSize) { chunk in
                        try await channel.send(chunk)
                        sent += Int64(chunk.count)
                        progress(sent)
                    }
                }
            } catch {
                // Stop here: the server sees a short input and changes nothing.
                channel.close(promise: nil)
                _ = await outcome
                throw error
            }
            // End of input: the command checks the length, then moves the file into place.
            try? await channel.close(mode: .output).get()
            let (code, stderr) = await outcome
            try Task.checkCancellation()
            guard code == 0 else { throw Self.failure(code, stderr) }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    public func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (channel, events) = try await openSessionChannel()
        try await withTaskCancellationHandler {
            try await channel.request(SSHChannelRequestEvent.ExecRequest(command: remoteCommand, wantReply: false))
            try? await channel.close(mode: .output).get()
            var file: FileHandle?
            var extractor: TarExtractor?
            switch sink {
            case .file(let url):
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    channel.close(promise: nil)
                    throw TransferError.failed("Couldn't create \(url.lastPathComponent) on this device.")
                }
                file = try FileHandle(forWritingTo: url)
            case .folder(let into):
                extractor = TarExtractor(into: into)
            }
            defer { try? file?.close() }
            var received: Int64 = 0
            var stderr = ByteBuffer()
            var code: Int32 = -1
            do {
                for await event in events {
                    switch event {
                    case .stdout(let bytes):
                        let data = Data(bytes.readableBytesView)
                        if let file { try file.write(contentsOf: data) } else { try extractor?.feed(data) }
                        received += Int64(data.count)
                        progress(received)
                    case .stderr(var bytes): stderr.writeBuffer(&bytes)
                    case .exit(let status): code = status
                    case .closed: break
                    }
                }
                try Task.checkCancellation()
                guard code == 0 else { throw Self.failure(code, String(buffer: stderr)) }
                try extractor?.finish()
            } catch {
                channel.close(promise: nil)
                throw error
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// The command's exit status and what it wrote to stderr, once the channel closes (stdout is not expected).
    private static func outcome(of events: AsyncStream<SessionEvent>) async -> (Int32, String) {
        var stderr = ByteBuffer()
        var code: Int32 = -1
        for await event in events {
            switch event {
            case .stderr(var bytes), .stdout(var bytes): stderr.writeBuffer(&bytes)
            case .exit(let status): code = status
            case .closed: break
            }
        }
        return (code, String(buffer: stderr))
    }

    private static func failure(_ code: Int32, _ stderr: String) -> TransferError {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return .failed(detail) }
        return .failed(code < 0 ? "The connection closed before the server finished." : "The server answered with status \(code).")
    }
}
