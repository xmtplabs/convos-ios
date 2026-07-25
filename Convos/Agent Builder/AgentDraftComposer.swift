import ConvosComposer
import ConvosCore
import SwiftUI

// AgentDraftComposer moved to the ConvosComposer package so the share
// extension can host the real builder draft UI. The app's view model
// conforms to the package's model protocol directly; connections (an
// app-only concept) map to the composer's generic chip slot.

extension AgentBuilderViewModel: AgentDraftComposing {
    var supportsVoiceMemo: Bool { true }
    var allowsVideoAttachments: Bool { true }

    /// Chips for the composer's attachments row, one per enabled connection.
    var agentDraftConnectionChips: [AgentDraftConnectionChip] {
        enabledConnections.map { connection in
            AgentDraftConnectionChip(
                id: connection.id,
                displayName: connection.displayName,
                chipImageName: connection.chipImageName
            ) { [weak self] in
                self?.removeConnection(connection)
            }
        }
    }
}
