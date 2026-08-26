import ConvosComposer
import ConvosCore
import PhotosUI
import SwiftUI
import UIKit

struct DocAskItemCard: View {
    let item: DocWaitingItem
    let sendState: DocItemSendState?
    let isEnabled: Bool
    @Binding var activeAnswerItemId: String?
    let onShareNumber: () -> Void
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void
    let onPhoto: (UIImage) -> Void

    @State private var answerText: String = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        DocItemCardContainer(itemId: item.id) {
            if case .resolving = sendState {
                DocItemResolvingView(label: "Done")
            } else {
                content
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                onAnswer(.action(.discard, edited: nil))
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .tint(.gray)
            .disabled(!actionsAreEnabled)
        }
        .onChange(of: selectedPhotos) { _, photos in
            load(photos)
        }
        .accessibilityIdentifier("doc-ask-" + item.id)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            DocItemKindLine(
                title: "Ask · " + kindTitle,
                systemImage: "sparkle",
                color: .accentColor
            )

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            action

            if case .failed = sendState {
                DocItemRetryView(label: "Couldn't send your answer", onRetry: onRetry)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var action: some View {
        switch item.kind {
        case .bindGroup:
            Button("Share Doc's number", systemImage: "person.badge.plus", action: onShareNumber)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minHeight: 44.0)
                .disabled(!actionsAreEnabled)
        case .catchup:
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: maxPendingMediaAttachments,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose screenshots", systemImage: "photo.on.rectangle.angled")
                    .frame(minHeight: 44.0)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!actionsAreEnabled)
        case .staleCheck:
            DocAnswerChips(
                chips: item.chips.isEmpty ? ["Keep active", "Pause", "Archive"] : item.chips,
                isEnabled: actionsAreEnabled
            ) {
                onAnswer(.choice($0))
            }
        case .nameContributors:
            DocInlineAnswerField(
                itemId: item.id,
                compactLabel: "Name contributors…",
                placeholder: "+1 628… = Sara",
                text: $answerText,
                activeItemId: $activeAnswerItemId,
                isEnabled: actionsAreEnabled
            ) {
                onAnswer(.text($0))
            }
        default:
            EmptyView()
        }
    }

    private var actionsAreEnabled: Bool {
        isEnabled && sendState == nil
    }

    private var kindTitle: String {
        switch item.kind {
        case .bindGroup:
            "Add to group"
        case .catchup:
            "Catch up"
        case .staleCheck:
            "Status"
        case .nameContributors:
            "Names"
        default:
            "Request"
        }
    }

    private func load(_ photos: [PhotosPickerItem]) {
        guard !photos.isEmpty else { return }
        selectedPhotos = []
        Task { @MainActor in
            for photo in photos {
                guard let data = try? await photo.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                onPhoto(image)
            }
        }
    }
}
