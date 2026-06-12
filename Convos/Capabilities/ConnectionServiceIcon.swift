import ConvosCore
import Foundation

/// Maps connection services to their branded icon assets in the asset catalog.
/// Returns nil for services without a bundled asset so callers can fall back
/// to an SF Symbol.
///
/// Contract: `serviceId` is the backend services-catalog slug — the cloud
/// service id embedded in `composio.*` provider ids (e.g. "googlecalendar"
/// from "composio.googlecalendar"). Every case must return the name of an
/// image set that exists in `Convos/Assets.xcassets`, following the
/// `connection<ServiceDisplayName>` naming convention (e.g.
/// "connectionGoogleCalendar", "connectionAppleHealth"). When the catalog
/// gains a new branded service: add the asset under that name, then add the
/// matching case here. Unmapped slugs intentionally return nil — callers
/// render the provider's SF Symbol instead of a missing-asset image.
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
