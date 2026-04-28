import ConvosCore
import SwiftUI

struct CloudConnectionServiceInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let iconSystemName: String
    let iconBackgroundColor: Color
    let subtitle: String
}

enum CloudConnectionServiceCatalog {
    static let all: [CloudConnectionServiceInfo] = [
        CloudConnectionServiceInfo(
            id: "google_calendar",
            displayName: "Google Calendar",
            iconSystemName: "calendar",
            iconBackgroundColor: .blue,
            subtitle: "Share your calendar with conversations"
        ),
        CloudConnectionServiceInfo(
            id: "google_drive",
            displayName: "Google Drive",
            iconSystemName: "folder",
            iconBackgroundColor: .green,
            subtitle: "Share files with conversations"
        ),
    ]

    static func info(for serviceId: String) -> CloudConnectionServiceInfo? {
        all.first { $0.id == serviceId }
    }

    static func displayName(for serviceId: String, fallback: String? = nil) -> String {
        if let info = info(for: serviceId) {
            return info.displayName
        }
        return fallback.map { $0.isEmpty ? serviceId : $0 } ?? serviceId
    }
}
