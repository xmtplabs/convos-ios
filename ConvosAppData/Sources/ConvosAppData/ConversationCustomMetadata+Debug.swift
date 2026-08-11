import Foundation
import SwiftProtobuf

public struct ConversationCustomMetadataDebugSnapshot: Sendable {
    public let rawAppData: String?
    public let rawAppDataByteCount: Int
    public let parsedMetadata: ConversationCustomMetadata
    public let roundTripEncodedMetadata: String?
    public let parseLooksLossless: Bool

    public init(rawAppData: String?) {
        self.rawAppData = rawAppData
        rawAppDataByteCount = rawAppData?.utf8.count ?? 0
        parsedMetadata = ConversationCustomMetadata.parseAppData(rawAppData)
        roundTripEncodedMetadata = try? parsedMetadata.toCompactString()
        parseLooksLossless = rawAppData == roundTripEncodedMetadata
    }

    public var debugText: String {
        [
            "rawAppDataByteCount: \(rawAppDataByteCount)",
            "rawAppData:",
            rawAppData ?? "<nil>",
            "",
            "roundTripEncodedMetadata:",
            roundTripEncodedMetadata ?? "<encoding failed>",
            "",
            "parseLooksLossless: \(parseLooksLossless)",
            "",
            "appDataFields:",
            appDataFieldsDebugText
        ].joined(separator: "\n")
    }

    /// Per-field breakdown of the appData payload: one section per field
    /// number occurrence, straight from the protobuf wire format. Field
    /// numbers the schema knows are decoded with the generated codec and
    /// dumped as objects; unknown numbers (and known ones whose bytes fail
    /// to decode) fall back to JSON when they parse, then text when they
    /// decode cleanly, and hex otherwise.
    public var appDataFieldsDebugText: String {
        guard let rawAppData, !rawAppData.isEmpty else {
            return "<no app data>"
        }

        let payload: Data
        do {
            payload = try AppDataRawFields.payloadBytes(from: rawAppData)
        } catch {
            return "<failed to decode payload: \(error.localizedDescription)>"
        }

        guard let fields = AppDataRawFields.fields(in: payload) else {
            return "<not valid protobuf wire format>\nhex: \(payload.toHexString())"
        }
        guard !fields.isEmpty else {
            return "<empty payload>"
        }

        let sections = fields.map { (field: AppDataRawField) -> String in
            field.debugSection
        }
        return sections.joined(separator: "\n\n")
    }
}

extension AppDataRawField {
    /// Renders one field occurrence as "[number] name-or-kind:" followed by
    /// the value on its own line(s). Known field numbers decode through the
    /// generated codec; anything else renders raw.
    var debugSection: String {
        if let known = knownFieldSection {
            return known
        }
        return rawSection
    }

    /// Schema-aware rendering for ConversationCustomMetadata's field
    /// numbers. Returns nil when the number is unknown, the wire type does
    /// not match the schema, or the codec rejects the bytes -- all of which
    /// fall back to the raw rendering.
    private var knownFieldSection: String? {
        switch (number, value) {
        case (1, .lengthDelimited(let data)):
            return Self.stringSection(number: number, name: "tag", data: data)
        case (2, .lengthDelimited(let data)):
            return Self.messageSection(number: number, name: "profiles", data: data, as: ConversationProfile.self)
        case (3, .fixed64(let raw)):
            let unix = Int64(bitPattern: raw)
            let date = Date(timeIntervalSince1970: TimeInterval(unix))
            return "[\(number)] expiresAtUnix:\n\(unix) (\(date))"
        case (4, .lengthDelimited(let data)):
            return "[\(number)] imageEncryptionKey:\n\(data.toHexString())"
        case (5, .lengthDelimited(let data)):
            return Self.messageSection(number: number, name: "encryptedGroupImage", data: data, as: EncryptedImageRef.self)
        case (6, .lengthDelimited(let data)):
            return Self.stringSection(number: number, name: "emoji", data: data)
        case (8, .lengthDelimited(let data)):
            return Self.messageSection(number: number, name: "agentDm", data: data, as: AgentDmInfo.self)
        case (9, .varint(let raw)):
            guard let rawValue = Int(exactly: raw), let mode = ParticipationMode(rawValue: rawValue) else {
                return nil
            }
            return "[\(number)] participationMode:\n\(String(describing: mode)) (\(raw))"
        case (10, .lengthDelimited(let data)):
            return Self.stringSection(number: number, name: "spaceUrl", data: data)
        case (11, .lengthDelimited(let data)):
            return Self.messageSection(number: number, name: "humanDm", data: data, as: HumanDmInfo.self)
        default:
            return nil
        }
    }

    private var rawSection: String {
        switch value {
        case .varint(let raw):
            return "[\(number)] varint:\n\(raw)"
        case .fixed64(let raw):
            return "[\(number)] fixed64:\n\(Int64(bitPattern: raw))"
        case .fixed32(let raw):
            return "[\(number)] fixed32:\n\(raw)"
        case .lengthDelimited(let data):
            if let json = Self.prettyJSON(data) {
                return "[\(number)] json:\n\(json)"
            }
            if let text = Self.printableText(data) {
                return "[\(number)] text:\n\(text)"
            }
            return "[\(number)] hex:\n\(data.toHexString())"
        }
    }

    private static func stringSection(number: Int, name: String, data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return "[\(number)] \(name):\n\(text)"
    }

    private static func messageSection(number: Int, name: String, data: Data, as type: (some SwiftProtobuf.Message).Type) -> String? {
        guard let message = try? type.init(serializedBytes: data) else { return nil }
        return "[\(number)] \(name):\n\(message.deepDebugDump)"
    }

    private static func prettyJSON(_ data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func printableText(_ data: Data) -> String? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let hasControlCharacters = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t") || scalar.value == 0x7F
        }
        return hasControlCharacters ? nil : text
    }
}

extension SwiftProtobuf.Message {
    /// Recursive dump of every set field, including nested messages, via
    /// protobuf text format. `String(describing:)` is unusable for debug
    /// surfaces: SwiftProtobuf's `debugDescription` collapses to just the
    /// type name outside DEBUG builds, while text format traverses the full
    /// message everywhere.
    var deepDebugDump: String {
        let dump = textFormatString().trimmingCharacters(in: .whitespacesAndNewlines)
        return dump.isEmpty ? "<no fields set>" : dump
    }
}
