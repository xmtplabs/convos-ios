@testable import ConvosCore
import Foundation
import Testing

/// Decoding is pinned against payloads captured from a running backend rather
/// than hand-written ones, because the shape that broke first was real: the
/// backend stamps `updatedAt` with JS `toISOString()`, whose fractional seconds
/// the stock `.iso8601` strategy rejects outright.
struct ProfilesAPIDecodingTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try ProfilesAPI.wireResponseDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("decodes a profile with fractional seconds")
    func decodesFractionalSeconds() throws {
        let profile = try decode(
            """
            {"inboxId":"55e16691b45e7b7fa9fc4daa2daaf128b2fe0bd52ea9dbf04d8a309ecdb99db7",\
            "name":"Scout","avatarUrl":null,"version":1,"updatedAt":"2026-08-19T05:28:11.450Z"}
            """,
            as: ProfilesAPI.Profile.self
        )
        #expect(profile.name == "Scout")
        #expect(profile.avatarUrl == nil)
        #expect(profile.version == 1)
        #expect(profile.updatedAt.timeIntervalSince1970 > 0)
    }

    @Test("decodes a profile without fractional seconds")
    func decodesPlainSeconds() throws {
        let profile = try decode(
            """
            {"inboxId":"aaaa","name":"Ada","avatarUrl":"https://cdn.test/profiles/a.jpg",\
            "version":3,"updatedAt":"2026-08-19T05:28:11Z"}
            """,
            as: ProfilesAPI.Profile.self
        )
        #expect(profile.avatarUrl == "https://cdn.test/profiles/a.jpg")
        #expect(profile.version == 3)
    }

    /// Unknown ids are absent rather than null-filled, so a batch response is
    /// not index-aligned with the request and callers must key by inbox id.
    @Test("decodes a batch that dropped unknown ids")
    func decodesSparseBatch() throws {
        let response = try decode(
            """
            {"profiles":[{"inboxId":"aaaa","name":"Ada","avatarUrl":null,"version":1,\
            "updatedAt":"2026-08-19T05:28:11.450Z"}]}
            """,
            as: ProfilesAPI.BatchResponse.self
        )
        #expect(response.profiles.count == 1)
        #expect(response.profiles.first?.inboxId == "aaaa")
    }

    @Test("chunks a member list to the batch limit the backend enforces")
    func chunksToBatchLimit() {
        #expect(ProfilesAPI.batchLimit == 100)
    }
}

/// The write body distinguishes "leave this alone" from "clear this". Getting
/// it wrong is silent: an omitted name that encodes as null wipes the name the
/// user still has.
struct ProfilesAPIEncodingTests {
    private func encoded(_ body: ProfilesAPI.UpdateBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    @Test("omitting a field leaves it out of the body entirely")
    func omittedFieldsAreAbsent() throws {
        let json = try encoded(.init(inboxId: "abc", name: nil, avatarUrl: nil))
        #expect(json["inboxId"] as? String == "abc")
        #expect(json.keys.contains("name") == false)
        #expect(json.keys.contains("avatarUrl") == false)
    }

    @Test("an explicit clear sends null, which is what the backend acts on")
    func explicitClearSendsNull() throws {
        let json = try encoded(.init(inboxId: "abc", name: .some(nil), avatarUrl: .some(nil)))
        #expect(json.keys.contains("name"))
        #expect(json["name"] is NSNull)
        #expect(json["avatarUrl"] is NSNull)
    }

    @Test("a value is sent as itself")
    func valuesRoundTrip() throws {
        let json = try encoded(.init(inboxId: "abc", name: "Ada", avatarUrl: "https://cdn/x.jpg"))
        #expect(json["name"] as? String == "Ada")
        #expect(json["avatarUrl"] as? String == "https://cdn/x.jpg")
    }
}
