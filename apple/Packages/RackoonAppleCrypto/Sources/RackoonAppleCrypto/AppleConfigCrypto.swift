import CommonCrypto
import Compression
import CryptoKit
import Foundation
import RackoonCore

/// `ConfigCrypto` on Apple platforms (spec/config-transfer.md): CryptoKit AES-256-GCM and SHA-256, CommonCrypto
/// PBKDF2-HMAC-SHA256, and the Compression framework's raw DEFLATE (its COMPRESSION_ZLIB is RFC 1951 with no header).
/// Used by the Mac and iPhone apps and by RackoonCoreTests on Apple hosts; RackoonCore itself stays Foundation-only.
public struct AppleConfigCrypto: ConfigCrypto {
    public init() {}

    public func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public func pbkdf2SHA256(password: Data, salt: Data, iterations: Int) throws -> Data {
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { outBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw ConfigCryptoFailure.corrupt }
        return out
    }

    public func sealAESGCM(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    public func openAESGCM(key: Data, nonce: Data, sealed: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16 else { throw ConfigCryptoFailure.authentication }
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw ConfigCryptoFailure.authentication
        }
    }

    public func deflate(_ data: Data) throws -> Data {
        try run(COMPRESSION_STREAM_ENCODE, data, limit: Int.max)
    }

    public func inflate(_ data: Data, limit: Int) throws -> Data {
        try run(COMPRESSION_STREAM_DECODE, data, limit: limit)
    }

    public func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// One pass of compression_stream over `input`, stopping with `.tooLarge` once the output passes `limit`.
    private func run(_ operation: compression_stream_operation, _ input: Data, limit: Int) throws -> Data {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConfigCryptoFailure.corrupt
        }
        defer { compression_stream_destroy(streamPointer) }
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            streamPointer.pointee.src_size = input.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
                if output.count > limit { throw ConfigCryptoFailure.tooLarge }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // No progress with input left means the data ended early.
                    if streamPointer.pointee.src_size == 0 && streamPointer.pointee.dst_size == bufferSize { throw ConfigCryptoFailure.corrupt }
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw ConfigCryptoFailure.corrupt
                }
            }
        }
        return output
    }
}
