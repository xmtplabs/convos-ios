import AVFoundation
import ConvosCore
import SwiftUI

/// The "summary card" cell that replaces the user's prompt + early agent
/// chatter at the top of a post-Make agent conversation. Reproduces the
/// AgentDraftComposer's rounded-rect liquid-glass styling (no bottom
/// buttons, no Make button) and the same attachment chips minus their X
/// buttons. Footer reads "You created an agent" in the group-update text
/// style.
struct AgentBuilderSummaryView: View {
    let summary: AgentBuilderSummary
    /// Namespace owned by `AgentBuilderView`. When non-nil the card pairs
    /// with the composer's glass rect via `glassEffectID +
    /// glassEffectTransition(.matchedGeometry)`, producing the morph on Make.
    /// Nil for the "returning later" case where the card simply renders
    /// in-place without an entry animation.
    var transitionNamespace: Namespace.ID?

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // `GlassEffectContainer` gives iOS a stable scope to coordinate
            // the card's backdrop-sampling pipeline. Standalone `.glassEffect`
            // inside a `UIHostingConfiguration` cell renders as opaque grey
            // on first mount because the cell is typically laid out off-screen
            // before being scrolled into view — the sampling layer has no
            // backdrop until the cell attaches to the window. The container
            // also scopes the matched-geometry transition cleanly to the
            // morph from the composer.
            GlassEffectContainer {
                card
            }
            Text("You created an agent")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var card: some View {
        if let transitionNamespace {
            cardContent
                .glassEffectID(AgentBuilderTransition.glassEffectId, in: transitionNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            if !summary.prompt.isEmpty {
                Text(summary.prompt)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !summary.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(summary.attachments) { attachment in
                            chipView(for: attachment)
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
                .scrollClipDisabled()
                .padding(.horizontal, -DesignConstants.Spacing.step4x)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: 24))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
    }

    @ViewBuilder
    private func chipView(for attachment: AgentBuilderSummaryAttachment) -> some View {
        switch attachment {
        case .photo(_, let thumbnailData):
            photoVideoChip(thumbnailData: thumbnailData, isVideo: false)
        case .video(_, let thumbnailData):
            photoVideoChip(thumbnailData: thumbnailData, isVideo: true)
        case let .file(_, filename, _, _):
            fileChip(filename: filename)
        case let .voiceMemo(_, duration, levels):
            voiceMemoChip(duration: duration, levels: levels)
        case let .connection(_, identifier):
            connectionChip(identifier: identifier)
        }
    }

    @ViewBuilder
    private func photoVideoChip(thumbnailData: Data?, isVideo: Bool) -> some View {
        Group {
            if let data = thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.colorFillSubtle
            }
        }
        .frame(width: chipSize, height: chipSize)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .overlay(alignment: .bottomLeading) {
            if isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 16.0, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .padding(.bottom, DesignConstants.Spacing.step2x)
                    .padding(.leading, DesignConstants.Spacing.step2x)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func fileChip(filename: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.colorTextSecondary)
            Text(filename)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .frame(width: chipSize, height: chipSize)
        .background(.colorFillSubtle)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    @ViewBuilder
    private func voiceMemoChip(duration: TimeInterval, levels: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(formattedDuration(duration))
                .font(.caption2)
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer(minLength: 0)
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                VoiceMemoWaveformView(
                    levels: levels,
                    progress: 0,
                    playedColor: .white,
                    unplayedColor: .white.opacity(0.4)
                )
                .frame(height: 24)
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(width: chipSize, height: chipSize)
        .background(.colorLava)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    @ViewBuilder
    private func connectionChip(identifier: String) -> some View {
        let imageName: String? = AgentBuilderConnection(rawValue: identifier)?.chipImageName
        Group {
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.colorFillSubtle
            }
        }
        .frame(width: chipSize, height: chipSize)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private let chipSize: CGFloat = 80
}

#Preview {
    let summary = AgentBuilderSummary(
        prompt: "Help me plan a backpacking trip across Patagonia. I want to camp 4 nights and finish in El Chaltén.",
        attachments: [
            .photo(id: UUID(), thumbnailData: nil),
            .file(id: UUID(), filename: "itinerary.pdf", mimeType: "application/pdf", fileSize: 12_345),
            .voiceMemo(id: UUID(), duration: 18, levels: Array(repeating: 0.6, count: 40)),
            .connection(id: UUID(), identifier: "googleCalendar"),
        ],
        cutoffDate: Date()
    )
    return AgentBuilderSummaryView(summary: summary)
        .padding()
}
