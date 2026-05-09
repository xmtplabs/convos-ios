import ConvosConnections
import Foundation

/// Static `ActionSchema` values published by `ScreenTimeDataSink`.
///
/// Real-world Screen Time writes need a `FamilyActivitySelection` bundle that the *user*
/// picks via Apple's `FamilyActivityPicker`. The agent can't enumerate apps on its own —
/// iOS only exposes opaque tokens scoped to a single selection. So the action set here
/// is split:
///
/// - `apply_selection` re-applies a previously-serialized selection bundle as a shield.
/// - `clear_shields` removes all restrictions on the default `ManagedSettingsStore`.
public enum ScreenTimeActionSchemas {
    public static let applySelection: ActionSchema = ActionSchema(
        kind: .screenTime,
        actionName: "apply_selection",
        capability: .writeUpdate,
        summary: "Apply a previously-saved FamilyActivitySelection as a shield on the default store.",
        inputs: [
            ActionParameter(
                name: "selectionData",
                type: .string,
                description: "Base64-encoded JSON of a FamilyActivitySelection, produced by a prior user picker interaction.",
                isRequired: true
            ),
        ],
        outputs: [
            ActionParameter(name: "applicationCount", type: .int, description: "Number of applications in the applied selection.", isRequired: true),
            ActionParameter(name: "categoryCount", type: .int, description: "Number of categories in the applied selection.", isRequired: true),
            ActionParameter(name: "webDomainCount", type: .int, description: "Number of web domains in the applied selection.", isRequired: true),
        ]
    )

    public static let clearShields: ActionSchema = ActionSchema(
        kind: .screenTime,
        actionName: "clear_shields",
        capability: .writeDelete,
        summary: "Remove all shields from the default ManagedSettingsStore.",
        inputs: [],
        outputs: []
    )

    public static let all: [ActionSchema] = [applySelection, clearShields]
}
