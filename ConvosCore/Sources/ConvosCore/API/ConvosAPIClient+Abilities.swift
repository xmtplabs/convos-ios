import Foundation

// MARK: - Abilities (V2) endpoints

extension ConvosAPIClient {
    func getAbilities() async throws -> AbilitiesAPI.CatalogResponse {
        let request = try abilitiesRequest(pathSegments: ["v2", "abilities"], method: "GET")
        return try await performAbilitiesRequest(request)
    }

    func createAbilityEntitlement(abilityId: String, redirectUri: String?) async throws -> AbilitiesAPI.EntitlementInitiationResponse {
        var request = try abilitiesRequest(
            pathSegments: ["v2", "abilities", abilityId, "entitlement"],
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct InitiationBody: Encodable {
            let redirectUri: String?
        }
        request.httpBody = try JSONEncoder().encode(InitiationBody(redirectUri: redirectUri))
        return try await performAbilitiesRequest(request)
    }

    @discardableResult
    func completeAbilityEntitlement(abilityId: String, connectionRequestId: String) async throws -> AbilitiesAPI.EntitlementCompleteResponse {
        var request = try abilitiesRequest(
            pathSegments: ["v2", "abilities", abilityId, "entitlement", "complete"],
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct CompleteBody: Encodable {
            let connectionRequestId: String
        }
        request.httpBody = try JSONEncoder().encode(CompleteBody(connectionRequestId: connectionRequestId))
        return try await performAbilitiesRequest(request)
    }

    func revokeAbilityEntitlement(abilityId: String) async throws {
        let request = try abilitiesRequest(
            pathSegments: ["v2", "abilities", abilityId, "entitlement"],
            method: "DELETE"
        )
        try await performAbilitiesVoidRequest(request)
    }

    func getConversationAbilities(conversationId: String) async throws -> AbilitiesAPI.ConversationAbilitiesResponse {
        let request = try abilitiesRequest(
            pathSegments: ["v2", "conversations", conversationId, "abilities"],
            method: "GET"
        )
        return try await performAbilitiesRequest(request)
    }

    @discardableResult
    func putConversationAbility(
        conversationId: String,
        abilityId: String,
        agentInboxId: String,
        bundleIds: [String],
        extendedByInboxId: String?
    ) async throws -> AbilitiesAPI.ConversationAbilityEntry {
        var request = try abilitiesRequest(
            pathSegments: ["v2", "conversations", conversationId, "abilities", abilityId],
            method: "PUT"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct ExtendBody: Encodable {
            let agentInboxId: String
            let bundleIds: [String]
            let extendedByInboxId: String?
        }
        request.httpBody = try JSONEncoder().encode(
            ExtendBody(agentInboxId: agentInboxId, bundleIds: bundleIds, extendedByInboxId: extendedByInboxId)
        )
        return try await performAbilitiesRequest(request)
    }

    func deleteConversationAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        let request = try abilitiesRequest(
            pathSegments: ["v2", "conversations", conversationId, "abilities", abilityId],
            method: "DELETE",
            queryParameters: ["agentInboxId": agentInboxId]
        )
        try await performAbilitiesVoidRequest(request)
    }
}

// MARK: - Shared plumbing

private extension ConvosAPIClient {
    func abilitiesRequest(
        pathSegments: [String],
        method: String,
        queryParameters: [String: String]? = nil
    ) throws -> URLRequest {
        try endpointRequest(
            pathSegments: pathSegments,
            method: method,
            queryParameters: queryParameters
        )
    }

    func performAbilitiesRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw abilitiesEndpointError(statusCode: httpResponse.statusCode, data: data, path: request.url?.path())
        }
        return try AbilitiesAPI.wireResponseDecoder().decode(T.self, from: data)
    }

    func performAbilitiesVoidRequest(_ request: URLRequest) async throws {
        let (data, httpResponse) = try await performAuthenticatedRequest(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw abilitiesEndpointError(statusCode: httpResponse.statusCode, data: data, path: request.url?.path())
        }
    }

    /// Typed mapping first (`{code, ...}` bodies the client acts on), then
    /// the same generic `APIError` fallback `performRequest` uses.
    func abilitiesEndpointError(statusCode: Int, data: Data, path: String?) -> Error {
        Log.error("\(path ?? "abilities endpoint") failed [\(statusCode)]: \(String(data: data, encoding: .utf8) ?? "nil data")")
        if let typed = AbilitiesAPI.EndpointError(body: data) {
            return typed
        }
        switch statusCode {
        case 400:
            return APIError.badRequest(parseErrorMessage(from: data))
        case 403:
            return APIError.forbidden
        case 404:
            return APIError.notFound
        default:
            return APIError.serverError(parseErrorMessage(from: data))
        }
    }
}
