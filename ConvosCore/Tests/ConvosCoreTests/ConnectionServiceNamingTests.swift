@testable import ConvosCore
import Foundation
import Testing

@Suite("CloudConnectionServiceNaming Tests")
struct ConnectionServiceNamingTests {
    @Test("Canonical -> Composio slug for mapped services")
    func mappedServices() {
        #expect(CloudConnectionServiceNaming.composioToolkitSlug(for: "google_calendar") == "googlecalendar")
        #expect(CloudConnectionServiceNaming.composioToolkitSlug(for: "google_drive") == "googledrive")
    }

    @Test("Unmapped services pass through unchanged")
    func unmappedPassThrough() {
        #expect(CloudConnectionServiceNaming.composioToolkitSlug(for: "slack") == "slack")
        #expect(CloudConnectionServiceNaming.composioToolkitSlug(for: "github") == "github")
        #expect(CloudConnectionServiceNaming.composioToolkitSlug(for: "notion") == "notion")
    }

    @Test("Composio slug -> canonical for mapped services")
    func reverseMapped() {
        #expect(CloudConnectionServiceNaming.canonicalService(fromComposioSlug: "googlecalendar") == "google_calendar")
        #expect(CloudConnectionServiceNaming.canonicalService(fromComposioSlug: "googledrive") == "google_drive")
    }

    @Test("Reverse lookup falls back to input for unknown slugs")
    func reverseUnmappedPassThrough() {
        #expect(CloudConnectionServiceNaming.canonicalService(fromComposioSlug: "google_calendar") == "google_calendar")
        #expect(CloudConnectionServiceNaming.canonicalService(fromComposioSlug: "slack") == "slack")
    }

    @Test("Round-trip canonical -> slug -> canonical")
    func roundTrip() {
        for canonical in ["google_calendar", "google_drive", "slack", "github"] {
            let slug = CloudConnectionServiceNaming.composioToolkitSlug(for: canonical)
            let restored = CloudConnectionServiceNaming.canonicalService(fromComposioSlug: slug)
            #expect(restored == canonical)
        }
    }
}
