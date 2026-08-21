import Foundation

// MARK: - Profiles (V2) endpoints

/// Display identity as the backend serves it: one row per person, resolved by
/// inbox id. Agents resolve through the same surface, so a caller rendering a
/// member list never has to know which kind of member it holds.
public enum ProfilesAPI {
    public struct Profile: Codable, Sendable, Hashable {
        public let inboxId: String
        public let name: String?
        public let avatarUrl: String?
        /// Monotonic, and bumped only when a value actually changes. The same
        /// number rides the XMTP change signal, so a client holding it can skip
        /// the fetch.
        public let version: Int
        public let updatedAt: Date
    }

    struct BatchResponse: Decodable {
        let profiles: [Profile]
    }

    struct BatchBody: Encodable {
        let inboxIds: [String]
    }

    /// A write to the caller's own profile. Absent means "leave alone",
    /// explicit null means "clear", which is why both levels are optional.
    struct UpdateBody: Encodable {
        let inboxId: String
        let name: String??
        let avatarUrl: String??

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inboxId, forKey: .inboxId)
            if let name { try container.encode(name, forKey: .name) }
            if let avatarUrl { try container.encode(avatarUrl, forKey: .avatarUrl) }
        }

        enum CodingKeys: String, CodingKey {
            case inboxId, name, avatarUrl
        }
    }

    struct AvatarUploadTicket: Decodable {
        let objectKey: String
        let uploadUrl: String
        let avatarUrl: String
    }

    /// The backend rejects a larger batch outright, so the client chunks rather
    /// than letting a big member list fail as one request.
    static let batchLimit: Int = 100

    /// The backend stamps `updatedAt` with JS `toISOString()`, which carries
    /// fractional seconds and so is rejected by the stock `.iso8601` strategy.
    /// `AbilitiesAPI` already had to solve this; the same decoder is reused
    /// rather than repeating the two-formatter dance.
    static func wireResponseDecoder() -> JSONDecoder {
        AbilitiesAPI.wireResponseDecoder()
    }
}

extension ConvosAPIClient {
    /// Resolves one person. Returns nil when the backend has no profile for the
    /// inbox — a normal outcome for someone who has not upgraded, not an error.
    public func getProfile(inboxId: String) async throws -> ProfilesAPI.Profile? {
        let request = try profilesRequest(pathSegments: ["v2", "profiles", inboxId], method: "GET")
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        if httpResponse.statusCode == 404 { return nil }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError(parseErrorMessage(from: data))
        }
        return try ProfilesAPI.wireResponseDecoder().decode(ProfilesAPI.Profile.self, from: data)
    }

    /// Resolves many people at once — the workhorse read for member lists and
    /// message authors. Unknown ids are simply absent from the result, so the
    /// caller must not assume the response is index-aligned with its input.
    public func getProfiles(inboxIds: [String]) async throws -> [ProfilesAPI.Profile] {
        let unique: [String] = Array(Set(inboxIds)).filter { !$0.isEmpty }
        guard !unique.isEmpty else { return [] }

        var resolved: [ProfilesAPI.Profile] = []
        for chunk in unique.chunkedForBatch(ProfilesAPI.batchLimit) {
            var request = try profilesRequest(pathSegments: ["v2", "profiles", "batch"], method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(ProfilesAPI.BatchBody(inboxIds: chunk))
            let (data, httpResponse) = try await performAuthenticatedRequest(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                throw APIError.serverError(parseErrorMessage(from: data))
            }
            let response = try ProfilesAPI.wireResponseDecoder()
                .decode(ProfilesAPI.BatchResponse.self, from: data)
            resolved.append(contentsOf: response.profiles)
        }
        return resolved
    }

    /// Writes the caller's own profile. The backend binds the inbox id to the
    /// account on first write and refuses any other claim, so this is the only
    /// profile this client can ever author.
    ///
    /// Omitting a field leaves it alone; passing `.some(nil)` clears it.
    @discardableResult
    func updateMyProfile(
        inboxId: String,
        name: String?? = nil,
        avatarUrl: String?? = nil
    ) async throws -> ProfilesAPI.Profile {
        var request = try profilesRequest(pathSegments: ["v2", "profiles", "me"], method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProfilesAPI.UpdateBody(inboxId: inboxId, name: name, avatarUrl: avatarUrl)
        )
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError(parseErrorMessage(from: data))
        }
        return try ProfilesAPI.wireResponseDecoder().decode(ProfilesAPI.Profile.self, from: data)
    }

    /// Uploads an avatar and returns the URL to store on the profile.
    ///
    /// Deliberately not the shared attachment upload: profile avatars land
    /// under a key prefix the bucket's expiry lifecycle excludes, because a
    /// profile references its avatar indefinitely and an aged-out object would
    /// break every client rendering that person, days after a clean upload.
    func uploadProfileAvatar(data: Data, contentType: String = "image/jpeg") async throws -> String {
        let ticketRequest = try profilesRequest(
            pathSegments: ["v2", "profiles", "avatar-upload"],
            method: "GET",
            queryParameters: ["contentType": contentType]
        )
        let (ticketData, ticketResponse) = try await performAuthenticatedRequest(ticketRequest)
        guard (200...299).contains(ticketResponse.statusCode) else {
            throw APIError.serverError(parseErrorMessage(from: ticketData))
        }
        let ticket = try JSONDecoder().decode(ProfilesAPI.AvatarUploadTicket.self, from: ticketData)

        guard let uploadURL = URL(string: ticket.uploadUrl) else { throw APIError.invalidURL }
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "PUT"
        upload.setValue(contentType, forHTTPHeaderField: "Content-Type")
        upload.httpBody = data

        // Straight to S3, so this one does not go through the client's session:
        // the presigned URL carries its own authorization and our headers have
        // no business there.
        let (body, response) = try await URLSession.shared.data(for: upload)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 200 else {
            Log.error("Profile avatar upload failed (\(http.statusCode)): \(String(data: body, encoding: .utf8) ?? "nil")")
            throw APIError.serverError(nil)
        }
        return ticket.avatarUrl
    }

    private func profilesRequest(
        pathSegments: [String],
        method: String,
        queryParameters: [String: String]? = nil
    ) throws -> URLRequest {
        var url = baseURL
        for segment in pathSegments {
            url = url.appendingPathComponent(segment)
        }
        if let queryParameters, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return attachingAuthHeader(to: request)
    }
}

private extension Array {
    /// Splits into batches the backend will accept, preserving order. Named
    /// distinctly because two other subsystems already carry their own private
    /// `chunked(into:)`; consolidating them is a separate cleanup.
    func chunkedForBatch(_ size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
