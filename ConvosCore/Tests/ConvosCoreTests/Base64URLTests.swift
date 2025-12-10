@testable import ConvosCore
import Foundation
import Testing

/// Comprehensive tests for Base64URL encoding/decoding
///
/// Tests cover:
/// - URL-safe character substitution (+/- and /_)
/// - Padding removal and restoration
/// - Round-trip conversion
/// - Edge cases (empty data, various sizes)
/// - Invalid format handling
@Suite("Base64URL Encoding/Decoding Tests")
struct Base64URLTests {
    // MARK: - Encoding Tests

    @Test("Base64URL encoding replaces special characters")
    func encodingReplacesSpecialCharacters() {
        // Create data that will produce + and / in standard base64
        let testData = Data([0xFB, 0xFF, 0xBF]) // Produces "+/+/" in base64

        let base64 = testData.base64EncodedString()
        let base64URL = testData.base64URLEncoded()

        // Standard base64 should contain + and /
        #expect(base64.contains("+") || base64.contains("/"))

        // Base64URL should NOT contain + or /
        #expect(!base64URL.contains("+"))
        #expect(!base64URL.contains("/"))

        // Base64URL should contain - or _ instead
        #expect(base64URL.contains("-") || base64URL.contains("_"))
    }

    @Test("Base64URL encoding removes padding")
    func encodingRemovesPadding() {
        let testCases: [(Data, Bool)] = [
            (Data([0x00]), true), // Would have == padding
            (Data([0x00, 0x01]), true), // Would have = padding
            (Data([0x00, 0x01, 0x02]), false), // No padding needed
            (Data([0x00, 0x01, 0x02, 0x03]), true), // Would have = padding
        ]

        for (data, shouldHavePadding) in testCases {
            let base64 = data.base64EncodedString()
            let base64URL = data.base64URLEncoded()

            if shouldHavePadding {
                #expect(base64.contains("="))
            }

            // Base64URL should never have padding
            #expect(!base64URL.contains("="))
        }
    }

    @Test("Base64URL encoding empty data")
    func encodingEmptyData() {
        let emptyData = Data()
        let encoded = emptyData.base64URLEncoded()
        #expect(encoded.isEmpty)
    }

    @Test("Base64URL encoding various sizes")
    func encodingVariousSizes() {
        let testSizes = [1, 2, 3, 4, 5, 10, 32, 64, 100, 1000]

        for size in testSizes {
            let data = Data((0..<size).map { UInt8($0 % 256) })
            let encoded = data.base64URLEncoded()

            // Should not contain standard base64 special chars
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(!encoded.contains("="))

            // Should only contain base64url chars (plus * separator for iMessage compatibility)
            let validChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*")
            #expect(encoded.rangeOfCharacter(from: validChars.inverted) == nil)
        }
    }

    // MARK: - Decoding Tests

    @Test("Base64URL decoding valid strings")
    func decodingValidStrings() throws {
        let testCases: [(String, Data)] = [
            ("AAEC", Data([0x00, 0x01, 0x02])),
            ("AAECAw", Data([0x00, 0x01, 0x02, 0x03])),
        ]

        for (encoded, expectedData) in testCases {
            let decoded = try encoded.base64URLDecoded()
            #expect(decoded == expectedData)
        }
    }

    @Test("Base64URL decoding with URL-safe characters")
    func decodingURLSafeCharacters() throws {
        // Test data that produces - and _ in base64url
        let testData = Data([0xFB, 0xFF, 0xBF])
        let encoded = testData.base64URLEncoded()

        let decoded = try encoded.base64URLDecoded()
        #expect(decoded == testData)
    }

    @Test("Base64URL decoding without padding")
    func decodingWithoutPadding() throws {
        let testCases = [
            "AA", // Would need ==
            "AAE", // Would need =
            "AAEC" // No padding needed
        ]

        for encoded in testCases {
            let decoded = try encoded.base64URLDecoded()
            #expect(!decoded.isEmpty)
        }
    }

    @Test("Base64URL decoding empty string")
    func decodingEmptyString() throws {
        let decoded = try "".base64URLDecoded()
        #expect(decoded.isEmpty)
    }

    // MARK: - Round-Trip Tests

    @Test("Base64URL round-trip conversion")
    func roundTripConversion() throws {
        let testData = [
            Data([0x00]),
            Data([0x00, 0x01]),
            Data([0x00, 0x01, 0x02]),
            Data([0x00, 0x01, 0x02, 0x03]),
            Data([0xFB, 0xFF, 0xBF]), // Special chars test
            Data((0..<32).map { UInt8($0) }), // 32-byte inbox ID
            Data((0..<100).map { UInt8($0 % 256) }),
            Data()
        ]

        for original in testData {
            let encoded = original.base64URLEncoded()
            let decoded = try encoded.base64URLDecoded()
            #expect(decoded == original, "Round-trip failed for data of size \(original.count)")
        }
    }

    @Test("Base64URL round-trip with binary data")
    func roundTripBinaryData() throws {
        // Test with various binary patterns
        let testPatterns: [Data] = [
            Data([0xFF, 0xFF, 0xFF]), // All ones
            Data([0x00, 0x00, 0x00]), // All zeros
            Data([0xAA, 0xAA, 0xAA]), // Alternating pattern
            Data([0x55, 0x55, 0x55]), // Inverse alternating
        ]

        for original in testPatterns {
            let encoded = original.base64URLEncoded()
            let decoded = try encoded.base64URLDecoded()
            #expect(decoded == original)
        }
    }

    // MARK: - Invalid Format Tests

    @Test("Base64URL decoding invalid characters throws")
    func decodingInvalidCharactersThrows() {
        let invalidStrings = [
            "ABC!", // ! is not base64
            "ABC@", // @ is not base64
            "ABC#", // # is not base64
            "ABC$", // $ is not base64
            "ABC%", // % is not base64
            "ABC^", // ^ is not base64
            "ABC&", // & is not base64
            // Note: "*" is now a valid separator for iMessage compatibility (gets stripped before decoding)
            "ABC()", // () are not base64
        ]

        for invalidString in invalidStrings {
            #expect(throws: Base64URLError.self) {
                _ = try invalidString.base64URLDecoded()
            }
        }
    }

    @Test("Base64URL decoding whitespace throws")
    func decodingWhitespaceThrows() {
        let invalidStrings = [
            "ABC DEF",
            "ABC\nDEF",
            "ABC\tDEF",
            " ABCDEF",
            "ABCDEF ",
        ]

        for invalidString in invalidStrings {
            #expect(throws: Base64URLError.self) {
                _ = try invalidString.base64URLDecoded()
            }
        }
    }

    // MARK: - Comparison with Standard Base64

    @Test("Standard base64 chars in input")
    func standardBase64CharsInInput() throws {
        // Test that standard base64 chars (+ and /) work in input
        // They get left as-is and decoded as standard base64

        // Create data that will produce + and / in standard base64
        let testData = Data([0xFB, 0xFF, 0xBF])
        let standardBase64 = testData.base64EncodedString() // Contains + and /

        // This should decode successfully (converts - and _ to + and /, leaves + and / as-is)
        let decoded = try standardBase64.base64URLDecoded()
        #expect(decoded == testData)
    }

    @Test("Base64URL differs from standard base64 for special chars")
    func comparisonWithStandardBase64() {
        let testData = Data([0xFB, 0xFF, 0xBF])

        let standard = testData.base64EncodedString()
        let urlSafe = testData.base64URLEncoded()

        // They should differ in characters used
        #expect(standard != urlSafe)

        // Standard should have +/
        // URL-safe should have -_
        // (Exact characters depend on data, but they should differ)
    }

    @Test("Standard base64 with padding vs base64url without")
    func paddingComparison() {
        let testData = Data([0x00]) // Will need padding

        let standard = testData.base64EncodedString()
        let urlSafe = testData.base64URLEncoded()

        #expect(standard.contains("="))
        #expect(!urlSafe.contains("="))
    }

    // MARK: - Real-World Use Cases

    @Test("Invite code encoding")
    func inviteCodeEncoding() throws {
        // Simulate invite code data
        let inviteData = Data((0..<50).map { UInt8($0 % 256) })

        let encoded = inviteData.base64URLEncoded()

        // Should be URL-safe (no +/=)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))

        // Should be decodable
        let decoded = try encoded.base64URLDecoded()
        #expect(decoded == inviteData)
    }

    @Test("Metadata encoding")
    func metadataEncoding() throws {
        // Simulate metadata protobuf data
        let metadataData = Data([
            0x0A, 0x0B, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64
        ])

        let encoded = metadataData.base64URLEncoded()
        let decoded = try encoded.base64URLDecoded()

        #expect(decoded == metadataData)
    }

    // MARK: - Edge Cases

    @Test("Maximum URL length data")
    func largeDataEncoding() throws {
        // Test with relatively large data (1KB)
        let largeData = Data((0..<1024).map { UInt8($0 % 256) })

        let encoded = largeData.base64URLEncoded()

        // Verify it's URL-safe
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))

        let decoded = try encoded.base64URLDecoded()
        #expect(decoded == largeData)
    }

    @Test("All padding lengths work")
    func allPaddingLengths() throws {
        // Test data that would require different padding lengths
        let testCases: [Data] = [
            Data([0x00, 0x01, 0x02]), // No padding (3 bytes -> 4 chars)
            Data([0x00, 0x01]), // 1 padding (2 bytes -> 3 chars + =)
            Data([0x00]), // 2 padding (1 byte -> 2 chars + ==)
        ]

        for data in testCases {
            let encoded = data.base64URLEncoded()
            let decoded = try encoded.base64URLDecoded()
            #expect(decoded == data)
            #expect(!encoded.contains("="))
        }
    }

    @Test("Character set validation")
    func characterSetValidation() {
        let data = Data((0..<100).map { UInt8($0) })
        let encoded = data.base64URLEncoded()

        // Should only contain valid base64url characters (plus * separator for iMessage compatibility)
        let validChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*")
        #expect(encoded.rangeOfCharacter(from: validChars.inverted) == nil)
    }

    @Test("No control characters in output")
    func noControlCharacters() {
        let data = Data([0x00, 0x01, 0x02, 0x0A, 0x0D, 0x1B])
        let encoded = data.base64URLEncoded()

        // Should not contain any control characters
        let controlChars = CharacterSet.controlCharacters
        #expect(encoded.rangeOfCharacter(from: controlChars) == nil)
    }

    // MARK: - iMessage Separator Tests

    @Test("Long strings have separator inserted")
    func longStringsHaveSeparator() {
        // Create data that will encode to more than 300 characters
        // 225 bytes of data -> 300 base64 characters (no separator needed)
        // 226 bytes of data -> 302 base64 characters (separator needed at position 300)
        let largeData = Data((0..<226).map { UInt8($0 % 256) })
        let encoded = largeData.base64URLEncoded()

        // Should contain at least one * separator
        #expect(encoded.contains("*"))
    }

    @Test("Short strings have no separator")
    func shortStringsHaveNoSeparator() {
        // Create data that will encode to less than 300 characters
        // 100 bytes -> ~134 base64 characters
        let smallData = Data((0..<100).map { UInt8($0 % 256) })
        let encoded = smallData.base64URLEncoded()

        // Should NOT contain * separator
        #expect(!encoded.contains("*"))
    }

    @Test("Separator appears at correct intervals")
    func separatorAppearsAtCorrectIntervals() {
        // Create data that will encode to significantly more than 600 characters
        // 500 bytes -> ~667 base64 characters (should have 2 separators)
        let largeData = Data((0..<500).map { UInt8($0 % 256) })
        let encoded = largeData.base64URLEncoded()

        // Split by separator and check each chunk
        let chunks = encoded.split(separator: "*", omittingEmptySubsequences: false)

        // Should have multiple chunks
        #expect(chunks.count > 1, "Expected multiple chunks separated by *")

        // Each chunk (except possibly the last) should be 300 characters or less
        for (index, chunk) in chunks.enumerated() {
            if index < chunks.count - 1 {
                #expect(chunk.count == 300, "Chunk \(index) should be 300 characters, got \(chunk.count)")
            } else {
                #expect(chunk.count <= 300, "Last chunk should be 300 characters or less, got \(chunk.count)")
            }
        }
    }

    @Test("Round-trip with separator works")
    func roundTripWithSeparator() throws {
        // Test various large data sizes to ensure separator handling works correctly
        let testSizes = [300, 500, 600, 1000, 2000]

        for size in testSizes {
            let data = Data((0..<size).map { UInt8($0 % 256) })
            let encoded = data.base64URLEncoded()
            let decoded = try encoded.base64URLDecoded()
            #expect(decoded == data, "Round-trip failed for data of size \(size)")
        }
    }

    @Test("Decoding with asterisk separator strips it")
    func decodingStripsAsterisk() throws {
        // Manually create a string with * separators to ensure they're stripped
        let original = "AAEC" // Decodes to Data([0x00, 0x01, 0x02])
        let withSeparators = "AA*EC"

        let decodedOriginal = try original.base64URLDecoded()
        let decodedWithSeparators = try withSeparators.base64URLDecoded()

        #expect(decodedOriginal == decodedWithSeparators)
    }

    @Test("insertingSeparator helper works correctly")
    func insertingSeparatorHelper() {
        let input = "ABCDEFGHIJ"

        // Every 3 characters
        let result1 = input.insertingSeparator("*", every: 3)
        #expect(result1 == "ABC*DEF*GHI*J")

        // Every 5 characters
        let result2 = input.insertingSeparator("-", every: 5)
        #expect(result2 == "ABCDE-FGHIJ")

        // Every 1 character
        let result3 = input.insertingSeparator(".", every: 1)
        #expect(result3 == "A.B.C.D.E.F.G.H.I.J")

        // Interval larger than string
        let result4 = input.insertingSeparator("*", every: 20)
        #expect(result4 == "ABCDEFGHIJ")

        // Empty string
        let result5 = "".insertingSeparator("*", every: 3)
        #expect(result5 == "")
    }
}
