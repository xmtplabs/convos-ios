#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct CloudConnectionServiceInfo: Identifiable, Hashable {
    public let id: String
    public let displayName: String
    public let iconSystemName: String
    public let iconBackgroundColor: Color
    public let subtitle: String
}

public enum CloudConnectionServiceCatalog {
    public static let all: [CloudConnectionServiceInfo] = [
        CloudConnectionServiceInfo(
            id: "googlecalendar",
            displayName: "Google Calendar",
            iconSystemName: "calendar",
            iconBackgroundColor: .blue,
            subtitle: "Share your calendar with conversations"
        ),
        CloudConnectionServiceInfo(
            id: "googledrive",
            displayName: "Google Drive",
            iconSystemName: "folder",
            iconBackgroundColor: .green,
            subtitle: "Share files with conversations"
        ),
    ]

    public static func info(for serviceId: String) -> CloudConnectionServiceInfo? {
        all.first { $0.id == serviceId }
    }

    public static func displayName(for serviceId: String, fallback: String? = nil) -> String {
        if let info = info(for: serviceId) {
            return info.displayName
        }
        return fallback.map { $0.isEmpty ? serviceId : $0 } ?? serviceId
    }
}
#endif
