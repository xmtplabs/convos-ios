import Foundation

/// Cloud service identifiers in Convos use the **Composio toolkit slug** form
/// (`googlecalendar`, `googledrive`, `slack`, `github`, …) end-to-end — DB,
/// wire format, picker registry, agent runtime, and Composio's API. No
/// translation layer between iOS and Composio.
///
/// Display names mostly fall out of title-casing the slug (`slack` → "Slack",
/// `notion` → "Notion"), with explicit overrides for compound brand names
/// where the slug has no word boundary (`googlecalendar` → "Google Calendar").
public enum CloudConnectionServiceNaming {
    /// Slugs whose display name can't be derived from title-casing alone.
    /// Add an entry when a new compound-brand toolkit lands.
    private static let displayNameOverrides: [String: String] = [
        "googlecalendar": "Google Calendar",
        "googledrive": "Google Drive",
        "googlecontacts": "Google Contacts",
        "googletasks": "Google Tasks",
        "microsoftoutlook": "Microsoft Outlook",
    ]

    /// Humanize a service slug into something user-readable.
    /// `googlecalendar` → "Google Calendar", `slack` → "Slack". A non-empty
    /// `serviceName` (e.g. backend-supplied display label) wins over derivation.
    public static func displayName(for serviceName: String, fallbackFrom serviceId: String = "") -> String {
        let raw = serviceName.isEmpty ? serviceId : serviceName
        if let override = displayNameOverrides[raw.lowercased()] {
            return override
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
