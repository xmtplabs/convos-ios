import ConvosCore
import Foundation

/// Maps connection services to their branded icon assets in the asset catalog.
/// Returns nil for services without a bundled asset so callers can fall back
/// to an SF Symbol.
enum ConnectionServiceIcon {
    static func assetName(forServiceId serviceId: String?) -> String? {
        switch serviceId {
        case "googlecalendar":
            return "connectionGoogleCalendar"
        default:
            return nil
        }
    }

    static func assetName(forProviderId providerId: String?) -> String? {
        guard let providerId else { return nil }
        if providerId == "device.health" {
            return "connectionAppleHealth"
        }
        return assetName(forServiceId: ProviderID(rawValue: providerId).cloudServiceId)
    }
}
