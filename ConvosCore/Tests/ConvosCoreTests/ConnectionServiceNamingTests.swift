@testable import ConvosCore
import Foundation
import Testing

@Suite("ConnectionServiceNaming Tests")
struct ConnectionServiceNamingTests {
    @Test("Canonical -> Composio slug for mapped services")
    func mappedServices() {
        #expect(ConnectionServiceNaming.composioToolkitSlug(for: "google_calendar") == "googlecalendar")
        #expect(ConnectionServiceNaming.composioToolkitSlug(for: "google_drive") == "googledrive")
    }

    @Test("Unmapped services pass through unchanged")
    func unmappedPassThrough() {
        #expect(ConnectionServiceNaming.composioToolkitSlug(for: "slack") == "slack")
        #expect(ConnectionServiceNaming.composioToolkitSlug(for: "github") == "github")
        #expect(ConnectionServiceNaming.composioToolkitSlug(for: "notion") == "notion")
    }

    @Test("Composio slug -> canonical for mapped services")
    func reverseMapped() {
        #expect(ConnectionServiceNaming.canonicalService(fromComposioSlug: "googlecalendar") == "google_calendar")
        #expect(ConnectionServiceNaming.canonicalService(fromComposioSlug: "googledrive") == "google_drive")
    }

    @Test("Reverse lookup falls back to input for unknown slugs")
    func reverseUnmappedPassThrough() {
        #expect(ConnectionServiceNaming.canonicalService(fromComposioSlug: "google_calendar") == "google_calendar")
        #expect(ConnectionServiceNaming.canonicalService(fromComposioSlug: "slack") == "slack")
    }

    @Test("Round-trip canonical -> slug -> canonical")
    func roundTrip() {
        for canonical in ["google_calendar", "google_drive", "slack", "github"] {
            let slug = ConnectionServiceNaming.composioToolkitSlug(for: canonical)
            let restored = ConnectionServiceNaming.canonicalService(fromComposioSlug: slug)
            #expect(restored == canonical)
        }
    }
}
