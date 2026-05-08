@testable import ConvosCore
import Foundation
import Testing

@Suite("CloudConnectionServiceNaming Tests")
struct ConnectionServiceNamingTests {
    @Test("Compound-brand slugs use the override map")
    func overriddenDisplayNames() {
        #expect(CloudConnectionServiceNaming.displayName(for: "googlecalendar") == "Google Calendar")
        #expect(CloudConnectionServiceNaming.displayName(for: "googledrive") == "Google Drive")
        #expect(CloudConnectionServiceNaming.displayName(for: "googlecontacts") == "Google Contacts")
        #expect(CloudConnectionServiceNaming.displayName(for: "googletasks") == "Google Tasks")
        #expect(CloudConnectionServiceNaming.displayName(for: "microsoftoutlook") == "Microsoft Outlook")
    }

    @Test("Single-word slugs title-case via the fallback")
    func titleCaseFallback() {
        #expect(CloudConnectionServiceNaming.displayName(for: "slack") == "Slack")
        #expect(CloudConnectionServiceNaming.displayName(for: "github") == "Github")
        #expect(CloudConnectionServiceNaming.displayName(for: "notion") == "Notion")
    }

    @Test("Non-empty serviceName wins over fallback derivation")
    func serverProvidedNameWins() {
        #expect(
            CloudConnectionServiceNaming.displayName(for: "Google Calendar", fallbackFrom: "googlecalendar")
                == "Google Calendar"
        )
    }

    @Test("Override matching is case-insensitive on the slug")
    func overrideCaseInsensitive() {
        #expect(CloudConnectionServiceNaming.displayName(for: "GoogleCalendar") == "Google Calendar")
        #expect(CloudConnectionServiceNaming.displayName(for: "GOOGLEDRIVE") == "Google Drive")
    }
}
