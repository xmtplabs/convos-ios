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
    let onAnswer: (DocAnswer) -> Void
    let onRetry: () -> Void
    let onPhoto: (UIImage) -> Void

    @State private var answerText: String = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

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
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: DocScreenshotSelectionPolicy.maximumSelectionCount,
            matching: .images
        )
        .accessibilityActions {
            voiceOverActions
        }
        .accessibilityIdentifier("doc-ask-" + item.id)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            DocItemKindLine(
                title: "Ask · " + kindTitle,
                systemImage: "sparkle",
                color: .colorLava
            )

            Text(item.headline)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
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
            Button("Connect to a group", systemImage: "bubble.left.and.bubble.right.fill") {
                onAnswer(.choice("Bind group"))
            }
                .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
                .disabled(!actionsAreEnabled)
        case .catchup:
            catchupActions
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

    @ViewBuilder
    private var catchupActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                chooseScreenshotsButton(fullWidth: true)
                notNowButton(fullWidth: true)
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                chooseScreenshotsButton(fullWidth: false)
                notNowButton(fullWidth: false)
            }
        }
    }

    private func chooseScreenshotsButton(fullWidth: Bool) -> some View {
        Button {
            isPhotoPickerPresented = true
        } label: {
            Label("Choose screenshots", systemImage: "photo.on.rectangle.angled")
        }
        .convosButtonStyle(.rounded(fullWidth: fullWidth, backgroundColor: .colorLava))
        .frame(minHeight: 44.0)
        .disabled(!actionsAreEnabled)
    }

    private func notNowButton(fullWidth: Bool) -> some View {
        Button("Not now") {
            onAnswer(.action(.discard, edited: nil))
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minHeight: 44.0)
        .disabled(!actionsAreEnabled)
    }

    private var actionsAreEnabled: Bool {
        guard isEnabled else { return false }
        switch sendState {
        case .resolving, .awaitingDelivery:
            return false
        case .failed, nil:
            return true
        }
    }

    @ViewBuilder
    private var voiceOverActions: some View {
        switch item.kind {
        case .bindGroup:
            Button("Connect to a group") {
                guard actionsAreEnabled else { return }
                onAnswer(.choice("Bind group"))
            }
        case .catchup:
            Button("Choose screenshots") {
                guard actionsAreEnabled else { return }
                isPhotoPickerPresented = true
            }
            Button("Not now") {
                guard actionsAreEnabled else { return }
                onAnswer(.action(.discard, edited: nil))
            }
        case .staleCheck:
            ForEach(
                item.chips.isEmpty ? ["Keep active", "Pause", "Archive"] : item.chips,
                id: \.self
            ) { chip in
                Button("Answer \(chip)") {
                    guard actionsAreEnabled else { return }
                    onAnswer(.choice(chip))
                }
            }
        case .nameContributors:
            Button("Name contributors") {
                guard actionsAreEnabled else { return }
                activeAnswerItemId = item.id
            }
        default:
            EmptyView()
        }

        if item.kind != .catchup {
            Button("Dismiss") {
                guard actionsAreEnabled else { return }
                onAnswer(.action(.discard, edited: nil))
            }
        }
    }

    private var kindTitle: String {
        switch item.kind {
        case .bindGroup:
            "Connect group"
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
