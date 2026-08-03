#if canImport(UIKit)
import SwiftUI

/// One thing a member can attach, as it appears in the attachments menu.
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

    /// Outline marks, matching the participation menu's. The two cards open from
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

/// The attachments menu: the vertical card the composer's + opens. A named list
/// rather than a row of bare glyphs, so each option says what it is - and it
/// wears the participation card's surface and rows, since the two open from
/// adjacent controls and are the same kind of object.
public struct ComposerAttachmentsMenu: View {
    /// The rows to draw, in order. Defaults to the real attachments; a host
    /// running with the debug injector on appends `.debugInjector`.
    let actions: [ComposerAttachmentAction]
    let disabledActions: Set<ComposerAttachmentAction>
    /// Draws the glass card around the rows. Set `false` when the host already
    /// provides a surface.
    let showsBackground: Bool
    let onSelect: (ComposerAttachmentAction) -> Void

    public init(
        actions: [ComposerAttachmentAction] = ComposerAttachmentAction.standard,
        disabledActions: Set<ComposerAttachmentAction> = [],
        showsBackground: Bool = true,
        onSelect: @escaping (ComposerAttachmentAction) -> Void
    ) {
        self.actions = actions
        self.disabledActions = disabledActions
        self.showsBackground = showsBackground
        self.onSelect = onSelect
    }

    public var body: some View {
        let sideInset: CGFloat = showsBackground ? ComposerMenuMetrics.cardSideInset : 0
        let verticalInset: CGFloat = showsBackground ? DesignConstants.Spacing.step4x : 0
        VStack(alignment: .leading, spacing: ComposerMenuMetrics.rowSpacing) {
            ForEach(actions) { action in
                row(for: action)
            }
        }
        .padding(.horizontal, sideInset)
        .padding(.vertical, verticalInset)
        // Real glass, not a frosted fill: it refracts the transcript behind it,
        // which is what separates the card from the conversation without a
        // shadow bloomed under it.
        .modifier(ComposerMenuCardSurface(isEnabled: showsBackground))
        .accessibilityIdentifier("composer-attachments-menu")
    }

    private func row(for action: ComposerAttachmentAction) -> some View {
        let isDisabled: Bool = disabledActions.contains(action)
        let tint: Color = isDisabled ? Color.colorTextPrimary.opacity(0.3) : Color.colorTextPrimary
        return Button {
            onSelect(action)
        } label: {
            HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: action.iconSystemName)
                    .font(ComposerMenuMetrics.iconFont)
                    .foregroundStyle(tint)
                    .frame(width: ComposerMenuMetrics.iconGutter, alignment: .center)

                Text(action.title)
                    .font(.title3.weight(.regular))
                    .foregroundStyle(tint)

                Spacer(minLength: DesignConstants.Spacing.step2x)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerMenuRowButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("attachment-\(action.rawValue)-button")
    }
}

// MARK: - Previews

/// Backed by a mock chat gradient so the glass has something real to refract
/// (glass over a flat fill reads as a plain blurred box).
#Preview("Attachments menu") {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.25), .purple.opacity(0.15), .orange.opacity(0.20)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        ComposerAttachmentsMenu(disabledActions: [.voiceNote]) { _ in }
            .frame(maxWidth: 360)
            .padding()
    }
}
#endif
