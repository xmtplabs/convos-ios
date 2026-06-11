@testable import ConvosCore
import Foundation
import Testing

/// Tests for `ConnectionServicesStore` (the client-side cache over
/// `GET /v2/connections/services`) and the catalog's Codable shapes.
@Suite("ConnectionServicesStore Tests")
struct ConnectionServicesStoreTests {
    /// Serves catalogs from a queue (last entry repeats) and counts fetches,
    /// with a mutable clock so the TTL is testable without sleeping.
    private final class Harness: @unchecked Sendable {
        private(set) var fetchCount: Int = 0
        var responses: [[CloudConnectionsAPI.ServiceConfig]]
        var currentDate: Date = Date(timeIntervalSince1970: 1_000_000)

        init(responses: [[CloudConnectionsAPI.ServiceConfig]]) {
            self.responses = responses
        }

        func makeStore(ttl: TimeInterval = ConnectionServicesStore.cacheTTL) -> ConnectionServicesStore {
            ConnectionServicesStore(
                ttl: ttl,
                now: { [weak self] in self?.currentDate ?? Date() },
                fetchServices: { [weak self] in
                    guard let self else { return CloudConnectionsAPI.ServicesResponse(services: []) }
                    self.fetchCount += 1
                    let catalog = self.responses.first ?? []
                    if self.responses.count > 1 {
                        self.responses.removeFirst()
                    }
                    return CloudConnectionsAPI.ServicesResponse(services: catalog)
                }
            )
        }
    }

    private static func service(
        id: String = "googlecalendar",
        version: Int,
        bundleIds: [String] = ["calendar.events"]
    ) -> CloudConnectionsAPI.ServiceConfig {
        CloudConnectionsAPI.ServiceConfig(
            id: id,
            composioSlug: id,
            version: version,
            displayName: .init(values: ["en": id]),
            bundles: bundleIds.map {
                .init(
                    id: $0,
                    title: .init(values: ["en": $0]),
                    description: .init(values: ["en": "About \($0)"]),
                    defaultEnabled: false
                )
            }
        )
    }

    // MARK: - TTL

    @Test("Catalog reads within the TTL are served from cache; a read past it refetches")
    func ttlIsRespected() async throws {
        let harness = Harness(responses: [[Self.service(version: 1)]])
        let store = harness.makeStore()

        _ = try await store.catalog()
        _ = try await store.catalog()
        #expect(harness.fetchCount == 1)

        harness.currentDate.addTimeInterval(ConnectionServicesStore.cacheTTL - 1)
        _ = try await store.catalog()
        #expect(harness.fetchCount == 1, "a read just inside the TTL must not refetch")

        harness.currentDate.addTimeInterval(2)
        _ = try await store.catalog()
        #expect(harness.fetchCount == 2, "a read past the TTL must refetch")
    }

    @Test("invalidate() forces the next read to refetch regardless of TTL")
    func invalidateForcesRefetch() async throws {
        let harness = Harness(responses: [[Self.service(version: 1)], [Self.service(version: 2)]])
        let store = harness.makeStore()

        let first = try await store.service(id: "googlecalendar")
        #expect(first?.version == 1)

        await store.invalidate()
        let second = try await store.service(id: "googlecalendar")
        #expect(second?.version == 2)
        #expect(harness.fetchCount == 2)
    }

    // MARK: - Version-mismatch invalidation

    @Test("service(id:minimumVersion:) refetches when the cached entry is older than asked")
    func versionMismatchInvalidates() async throws {
        let harness = Harness(responses: [[Self.service(version: 1)], [Self.service(version: 3)]])
        let store = harness.makeStore()

        let cached = try await store.service(id: "googlecalendar")
        #expect(cached?.version == 1)

        let refreshed = try await store.service(id: "googlecalendar", minimumVersion: 3)
        #expect(refreshed?.version == 3)
        #expect(harness.fetchCount == 2)
    }

    @Test("service(id:minimumVersion:) serves the cache when it already satisfies the version")
    func versionMatchServesCache() async throws {
        let harness = Harness(responses: [[Self.service(version: 4)]])
        let store = harness.makeStore()

        _ = try await store.catalog()
        let hit = try await store.service(id: "googlecalendar", minimumVersion: 4)
        #expect(hit?.version == 4)
        #expect(harness.fetchCount == 1)
    }

    @Test("unknown service id resolves to nil without extra fetches")
    func unknownServiceIsNil() async throws {
        let harness = Harness(responses: [[Self.service(version: 1)]])
        let store = harness.makeStore()

        let missing = try await store.service(id: "not-a-service")
        #expect(missing == nil)
        #expect(harness.fetchCount == 1)
    }

    // MARK: - LocalizedString

    @Test("localized rendering picks the locale's language and falls back to en")
    func localizedFallsBackToEnglish() {
        let text = CloudConnectionsAPI.LocalizedString(values: ["en": "Events", "fr": "Événements"])
        #expect(text.resolved(for: Locale(identifier: "fr_FR")) == "Événements")
        #expect(text.resolved(for: Locale(identifier: "de_DE")) == "Events")

        let englishOnly = CloudConnectionsAPI.LocalizedString(values: ["en": "Events"])
        #expect(englishOnly.resolved(for: Locale(identifier: "ja_JP")) == "Events")

        let empty = CloudConnectionsAPI.LocalizedString(values: [:])
        #expect(empty.resolved(for: Locale(identifier: "en_US")).isEmpty)
    }

    // MARK: - Wire shape

    @Test("services response decodes the documented camelCase shape, tolerating unknown fields")
    func servicesResponseDecodes() throws {
        let json = """
        {
          "services": [
            {
              "id": "googlecalendar",
              "composioSlug": "googlecalendar",
              "version": 2,
              "displayName": { "en": "Google Calendar", "fr": "Google Agenda" },
              "someFutureField": { "nested": true },
              "bundles": [
                {
                  "id": "calendar.events",
                  "title": { "en": "Events" },
                  "description": { "en": "View and edit events on all calendars" },
                  "defaultEnabled": false,
                  "anotherFutureField": 7
                },
                {
                  "id": "calendar.events.read",
                  "title": { "en": "View events" },
                  "description": { "en": "View events on all calendars" },
                  "defaultEnabled": true
                }
              ]
            }
          ],
          "topLevelFutureField": "ignored"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(CloudConnectionsAPI.ServicesResponse.self, from: data)

        let service = try #require(response.services.first)
        #expect(service.id == "googlecalendar")
        #expect(service.composioSlug == "googlecalendar")
        #expect(service.version == 2)
        #expect(service.displayName.resolved(for: Locale(identifier: "en_US")) == "Google Calendar")
        #expect(service.icon == nil, "icon is optional and omitted in v1")
        #expect(service.bundles.count == 2)
        #expect(service.bundles.first?.id == "calendar.events")
        #expect(service.bundles.first?.defaultEnabled == false)
        #expect(service.bundles.last?.defaultEnabled == true)
    }

    @Test("an optional icon decodes when present")
    func iconDecodesWhenPresent() throws {
        let json = """
        {
          "services": [
            {
              "id": "googlecalendar",
              "composioSlug": "googlecalendar",
              "version": 1,
              "displayName": { "en": "Google Calendar" },
              "icon": { "format": "png", "base64": "aWNvbg==" },
              "bundles": []
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(CloudConnectionsAPI.ServicesResponse.self, from: data)
        #expect(response.services.first?.icon?.format == "png")
        #expect(response.services.first?.icon?.base64 == "aWNvbg==")
    }
}
