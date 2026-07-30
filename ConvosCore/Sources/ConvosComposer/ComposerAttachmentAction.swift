#if canImport(UIKit)
import SwiftUI

/// One thing a member can attach, as it appears in the attachments menu the
/// composer's `+` presents.
public enum ComposerAttachmentAction: String, CaseIterable, Identifiable, Sendable {
    case photos
    case camera
    case files
    case voiceNote
    /// Injects a canned attachment for testing. Only ever offered behind
    /// `FeatureFlags.isDebugInjectorEnabled`, which is hard-locked off in
    /// production - so it is absent from `standard` and a host has to ask for
    /// it by name.
    case debugInjector

    /// What the menu offers a member. Everything real, and nothing a build
    /// without the debug flag should ever see.
    public static let standard: [ComposerAttachmentAction] = [.photos, .camera, .files, .voiceNote]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photos: "Photos"
        case .camera: "Camera"
        case .files: "Files"
        case .voiceNote: "Voice note"
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
        case .debugInjector: "testtube.2"
        }
    }
}
#endif
