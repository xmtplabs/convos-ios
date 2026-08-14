import Foundation

/// Connections an agent-builder summary card can carry. The builder that
/// offered them is gone, but summary cards persisted before that are still in
/// transcripts, so the raw values stay as written and this maps them to the
/// chip artwork the card renders.
enum AgentBuilderConnection: String {
    case appleHealth
    case googleCalendar

    /// 80x80 brand image rendered as the chip on the summary card.
    var chipImageName: String {
        switch self {
        case .appleHealth: return "connectionAppleHealth"
        case .googleCalendar: return "connectionGoogleCalendar"
        }
    }
}
