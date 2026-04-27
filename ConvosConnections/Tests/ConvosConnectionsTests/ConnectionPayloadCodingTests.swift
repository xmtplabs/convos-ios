@testable import ConvosConnections
import Foundation
import Testing

@Suite("ConnectionPayload coding")
struct ConnectionPayloadCodingTests {
    @Test("health payload round-trips through JSON")
    func healthPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            source: .health,
            capturedAt: now,
            body: .health(
                HealthPayload(
                    summary: "3 workouts; 8h sleep",
                    samples: [
                        HealthSample(
                            type: .workout,
                            startDate: now.addingTimeInterval(-3600),
                            endDate: now,
                            value: 3600,
                            unit: "seconds",
                            metadata: ["activityType": "running"]
                        )
                    ],
                    rangeStart: now.addingTimeInterval(-86_400),
                    rangeEnd: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("calendar payload round-trips through JSON")
    func calendarPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .calendar,
            capturedAt: now,
            body: .calendar(
                CalendarPayload(
                    summary: "2 events",
                    events: [
                        CalendarEvent(
                            id: "event-1",
                            title: "Standup",
                            startDate: now,
                            endDate: now.addingTimeInterval(1800),
                            isAllDay: false,
                            location: "Zoom",
                            notes: nil,
                            calendarTitle: "Work",
                            status: .confirmed,
                            isRecurring: true
                        ),
                    ],
                    rangeStart: now.addingTimeInterval(-86_400),
                    rangeEnd: now.addingTimeInterval(14 * 86_400)
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("location payload round-trips through JSON")
    func locationPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .location,
            capturedAt: now,
            body: .location(
                LocationPayload(
                    summary: "1 arrival",
                    events: [
                        LocationEvent(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000abc") ?? UUID(),
                            type: .visitArrival,
                            latitude: 37.7749,
                            longitude: -122.4194,
                            horizontalAccuracy: 30.0,
                            eventDate: now,
                            arrivalDate: now,
                            departureDate: nil
                        ),
                    ],
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("contacts payload round-trips through JSON")
    func contactsPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .contacts,
            capturedAt: now,
            body: .contacts(
                ContactsPayload(
                    summary: "2 contacts",
                    totalContactCount: 2,
                    previewContacts: [
                        ContactSummary(
                            id: "c-1",
                            givenName: "Ada",
                            familyName: "Lovelace",
                            organization: nil,
                            hasEmail: true,
                            hasPhone: false
                        ),
                        ContactSummary(
                            id: "c-2",
                            givenName: nil,
                            familyName: nil,
                            organization: "Acme",
                            hasEmail: false,
                            hasPhone: true
                        ),
                    ],
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("photos payload round-trips through JSON")
    func photosPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .photos,
            capturedAt: now,
            body: .photos(
                PhotosPayload(
                    summary: "120 assets",
                    totalAssetCount: 120,
                    photoCount: 100,
                    videoCount: 20,
                    screenshotCount: 5,
                    livePhotoCount: 3,
                    recentAssets: [
                        PhotoAssetSummary(
                            id: "asset-1",
                            mediaType: .photo,
                            subtype: .livePhoto,
                            creationDate: now,
                            isFavorite: true,
                            latitude: 37.7,
                            longitude: -122.4
                        ),
                    ],
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("music payload round-trips through JSON")
    func musicPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .music,
            capturedAt: now,
            body: .music(
                MusicPayload(
                    summary: "All Too Well — Taylor Swift",
                    nowPlaying: NowPlayingItem(
                        title: "All Too Well",
                        artist: "Taylor Swift",
                        album: "Red",
                        genre: "Pop",
                        durationSeconds: 325,
                        playbackTimeSeconds: 42
                    ),
                    playbackState: .playing,
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("motion payload round-trips through JSON")
    func motionPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .motion,
            capturedAt: now,
            body: .motion(
                MotionPayload(
                    summary: "Walking (confidence: high)",
                    activity: MotionActivity(type: .walking, confidence: .high, startDate: now),
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("home payload round-trips through JSON")
    func homePayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .homeKit,
            capturedAt: now,
            body: .homeKit(
                HomePayload(
                    summary: "1 home, 5 accessories total.",
                    homes: [
                        HomeSummary(
                            id: "home-1",
                            name: "Main Street",
                            isPrimary: true,
                            roomCount: 4,
                            accessoryCount: 5
                        ),
                    ],
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("screen time payload round-trips through JSON")
    func screenTimePayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = ConnectionPayload(
            source: .screenTime,
            capturedAt: now,
            body: .screenTime(
                ScreenTimePayload(
                    summary: "Screen Time authorized.",
                    authorized: true,
                    selectedApplicationCount: 3,
                    selectedCategoryCount: 1,
                    selectedWebDomainCount: 0,
                    capturedAt: now
                )
            )
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test("unknown body type decodes without throwing")
    func unknownBodyTypeFallsBack() throws {
        let envelope: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000002",
            "schemaVersion": 1,
            "source": "health",
            "capturedAt": 1_700_000_000.0,
            "body": [
                "type": "future_source_we_havent_shipped_yet",
                "data": "AQID",
            ],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: envelope)

        let decoded = try JSONDecoder().decode(ConnectionPayload.self, from: jsonData)
        switch decoded.body {
        case .unknown(let rawType, _):
            #expect(rawType == "future_source_we_havent_shipped_yet")
        case .health, .calendar, .location, .contacts, .photos, .music, .motion, .homeKit, .screenTime:
            Issue.record("Expected unknown body case")
        }
    }
}
