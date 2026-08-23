/// One thing a member can attach or open from the composer, as it appears
/// in the attachments menu the composer's `+` presents.
///
/// This enum is the single declaration of what an option is: identity
/// (stable `rawValue` id), title, icon, and dispatch routing. The lists
/// below declare which options each surface offers.
///
/// Deliberately platform-neutral (no UIKit) so the curation and routing
/// rules stay testable from the package's macOS test run.
public enum ComposerAttachmentAction: String, CaseIterable, Identifiable, Sendable {
    case photos
    case camera
    case files
    case voiceNote
    /// Opens the host's Connections browser (account-level ability
    /// entitlements). Offered only in the agent composer, and only when the
    /// host passes `connectionsEnabled` - the composer package cannot read
    /// feature flags itself.
    case connections
    /// Injects a canned attachment for testing. Only ever offered behind
    /// `FeatureFlags.isDebugInjectorEnabled`, which is hard-locked off in
    /// production - so it is absent from `standard` and a host has to ask for
    /// it by name.
    case debugInjector

    /// What the group composer's menu offers a member. Everything real, and
    /// nothing a build without the debug flag should ever see.
    public static let standard: [ComposerAttachmentAction] = [.photos, .camera, .files, .voiceNote]

    /// The agent composer's `+` menu, and the only surface offering
    /// `.connections` - which joins only when the host enables it.
    public static func agentMenu(connectionsEnabled: Bool) -> [ComposerAttachmentAction] {
        agentMenuBase.filter { included($0, connectionsEnabled: connectionsEnabled) }
    }

    private static let agentMenuBase: [ComposerAttachmentAction] = [.photos, .camera, .files, .voiceNote, .connections]

    /// The one gate on `.connections`. No list carries it unconditionally
    /// and no surface consults the flag independently, so a side door would
    /// require bypassing this predicate.
    private static func included(_ action: ComposerAttachmentAction, connectionsEnabled: Bool) -> Bool {
        action != .connections || connectionsEnabled
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photos: "Photos"
        case .camera: "Camera"
        case .files: "Files"
        case .voiceNote: "Voice note"
        case .connections: "Connections"
        case .debugInjector: "Test attachment"
        }
    }

    /// Outline marks, matching the participation menu's. The two menus open from
    /// neighbouring controls, so a filled set here would read as a different
    /// menu borrowed from somewhere else.
    public var iconSystemName: String {
        switch self {
        case .photos: "photo"
        case .camera: "camera"
        case .files: "document"
        case .voiceNote: "waveform"
        case .connections: "powerplug"
        case .debugInjector: "testtube.2"
        }
    }

    /// Where a picked option routes. Every case resolves to one of the
    /// composer's own controls except `.hostConnections`, which the composer
    /// hands to the host through its `onConnectionsTap` callback - the
    /// Connections browser lives outside the composer package.
    public enum Dispatch: Equatable, Sendable {
        case photoPicker
        case cameraPicker
        case filePicker
        case voiceMemo
        case hostConnections
        case debugInjector
    }

    public var dispatch: Dispatch {
        switch self {
        case .photos: .photoPicker
        case .camera: .cameraPicker
        case .files: .filePicker
        case .voiceNote: .voiceMemo
        case .connections: .hostConnections
        case .debugInjector: .debugInjector
        }
    }
}
