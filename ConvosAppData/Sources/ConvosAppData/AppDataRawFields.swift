import Foundation

/// One field occurrence pulled straight out of the appData protobuf wire
/// format. Carries the field number and the raw wire value, with no
/// knowledge of the generated codec's schema -- so field numbers written by
/// newer clients still surface here.
public struct AppDataRawField: Sendable {
    public enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case lengthDelimited(Data)
    }

    public let number: Int
    public let value: Value
}

public enum AppDataRawFields {
    /// Decodes the raw appData string down to protobuf bytes, mirroring
    /// `fromCompactString`'s envelope handling (base64url plus optional
    /// DEFLATE) without touching the generated codec.
    public static func payloadBytes(from rawAppData: String) throws -> Data {
        let data = try rawAppData.base64URLDecoded()
        guard let firstByte = data.first, firstByte == Data.compressionMarker else {
            return data
        }
        guard let decompressed = data.dropFirst().decompressedWithSize(maxSize: Constant.maxDecompressedSize) else {
            throw AppDataError.decompressionFailed
        }
        return decompressed
    }

    /// Walks the payload as protobuf wire format, returning every field
    /// occurrence in wire order, or nil when the bytes are not valid wire
    /// format.
    public static func fields(in payload: Data) -> [AppDataRawField]? {
        let bytes = [UInt8](payload)
        var offset = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        var fields: [AppDataRawField] = []
        while offset < bytes.count {
            guard let key = readVarint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0, number <= Constant.maxFieldNumber else { return nil }
            switch key & 0x7 {
            case 0:
                guard let value = readVarint() else { return nil }
                fields.append(AppDataRawField(number: number, value: .varint(value)))
            case 1:
                guard offset + 8 <= bytes.count else { return nil }
                var value: UInt64 = 0
                for byteIndex in 0..<8 {
                    value |= UInt64(bytes[offset + byteIndex]) << (8 * UInt64(byteIndex))
                }
                offset += 8
                fields.append(AppDataRawField(number: number, value: .fixed64(value)))
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - offset) else { return nil }
                let end = offset + Int(length)
                fields.append(AppDataRawField(number: number, value: .lengthDelimited(Data(bytes[offset..<end]))))
                offset = end
            case 5:
                guard offset + 4 <= bytes.count else { return nil }
                var value: UInt32 = 0
                for byteIndex in 0..<4 {
                    value |= UInt32(bytes[offset + byteIndex]) << (8 * UInt32(byteIndex))
                }
                offset += 4
                fields.append(AppDataRawField(number: number, value: .fixed32(value)))
            default:
                return nil
            }
        }
        return fields
    }

    private enum Constant {
        static let maxDecompressedSize: UInt32 = 10 * 1024 * 1024
        static let maxFieldNumber: Int = 536_870_911
    }
}
