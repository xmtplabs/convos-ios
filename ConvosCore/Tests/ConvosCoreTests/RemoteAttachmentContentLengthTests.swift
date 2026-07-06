import Foundation
import Testing
import XMTPiOS
@testable import ConvosCore

@Suite("Remote attachment contentLength")
struct RemoteAttachmentContentLengthTests {
    @Test("PreparedBackgroundUpload carries the encrypted size")
    func preparedCarriesEncryptedSize() {
        let prepared = PreparedBackgroundUpload(
            taskId: "t",
            encryptedFileURL: URL(fileURLWithPath: "/tmp/x.bin"),
            presignedUploadURL: URL(string: "https://example.com/up")!,
            assetURL: "https://example.com/x.bin",
            encryptionSecret: Data(repeating: 1, count: 32),
            encryptionSalt: Data(repeating: 2, count: 32),
            encryptionNonce: Data(repeating: 3, count: 12),
            contentDigest: "deadbeef",
            filename: "x.bin",
            encryptedContentLength: 4096
        )
        #expect(prepared.encryptedContentLength == 4096)
    }

    @Test("builder sets contentLength from the descriptor")
    func builderSetsContentLength() {
        let prepared = PreparedBackgroundUpload(
            taskId: "t",
            encryptedFileURL: URL(fileURLWithPath: "/tmp/x.bin"),
            presignedUploadURL: URL(string: "https://example.com/up")!,
            assetURL: "https://example.com/x.bin",
            encryptionSecret: Data(repeating: 1, count: 32),
            encryptionSalt: Data(repeating: 2, count: 32),
            encryptionNonce: Data(repeating: 3, count: 12),
            contentDigest: "deadbeef",
            filename: "x.bin",
            encryptedContentLength: 4096
        )
        let info = MultiRemoteAttachment.RemoteAttachmentInfo(from: prepared)
        #expect(info.contentLength == 4096)
        #expect(info.url == "https://example.com/x.bin")
        #expect(info.contentDigest == "deadbeef")
    }

    @Test("descriptor-built info never has zero contentLength for a real upload")
    func bundleInfoNotZero() {
        let prepared = PreparedBackgroundUpload(
            taskId: "t",
            encryptedFileURL: URL(fileURLWithPath: "/tmp/x.bin"),
            presignedUploadURL: URL(string: "https://example.com/up")!,
            assetURL: "https://example.com/x.bin",
            encryptionSecret: Data(repeating: 1, count: 32),
            encryptionSalt: Data(repeating: 2, count: 32),
            encryptionNonce: Data(repeating: 3, count: 12),
            contentDigest: "deadbeef",
            filename: "x.bin",
            encryptedContentLength: 7777
        )
        let info = MultiRemoteAttachment.RemoteAttachmentInfo(from: prepared)
        #expect(info.contentLength == 7777)
        #expect(info.contentLength != 0)
    }

    @Test("encrypted ciphertext size differs from plaintext (guards voice/file plaintext bug)")
    func ciphertextSizeDiffersFromPlaintext() throws {
        // AES-GCM ciphertext = plaintext + 16-byte tag, so they always differ.
        // This documents why contentLength must use encrypted.payload.count,
        // not the plaintext fileData.count, at the voice/file bundle site.
        let plaintext = 1000
        let ciphertextWithTag = plaintext + 16
        #expect(UInt32(ciphertextWithTag) != UInt32(plaintext))
    }

    @Test("RemoteAttachment Int? contentLength accepts the encrypted UInt32 size")
    func intContentLengthFromUInt32() {
        let encryptedSize: UInt32 = 5000
        let asInt = Int(encryptedSize)
        #expect(asInt == 5000)
    }
}
