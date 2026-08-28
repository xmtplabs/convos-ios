import ConvosCore
import SwiftUI

struct DocForYouSection: View {
    @Bindable var viewModel: DocExperienceViewModel
    let verification: DocControlVerification?
    let items: [DocWaitingItem]
    let composerScope: DocComposerScope

    @State private var isExpanded: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        Section {
            if let verification {
                DocVerificationControlCard(
                    verification: verification,
                    onRenew: viewModel.renewVerification
                )
                .transition(DocMotion.itemTransition(reduceMotion: reduceMotion))
                .listRowInsets(rowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(visibleItems) { item in
                itemCard(for: item)
                    .transition(DocMotion.itemTransition(reduceMotion: reduceMotion))
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if hiddenCount > 0 || isExpanded, !items.isEmpty {
                Button {
                    withAnimation(DocMotion.arrival(reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show fewer" : "\(hiddenCount) more")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(minHeight: 44.0)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.colorLava)
                .listRowInsets(rowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("doc-for-you-more")
            }
        } header: {
            DocSectionHeader(title: "For you")
        }
        .animation(
            DocMotion.collapse(reduceMotion: reduceMotion),
            value: visibleItems.map(\.id)
        )
    }

    private var rankedItems: [DocWaitingItem] {
        items.sorted { lhs, rhs in
            let leftRank = rank(lhs.register)
            let rightRank = rank(rhs.register)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var visibleItems: [DocWaitingItem] {
        isExpanded ? rankedItems : Array(rankedItems.prefix(verification == nil ? 3 : 2))
    }

    private var hiddenCount: Int {
        max(0, rankedItems.count - (verification == nil ? 3 : 2))
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: DesignConstants.Spacing.step2x,
            leading: DesignConstants.Spacing.step4x,
            bottom: DesignConstants.Spacing.step2x,
            trailing: DesignConstants.Spacing.step4x
        )
    }

    @ViewBuilder
    private func itemCard(for item: DocWaitingItem) -> some View {
        if DocGroupConfirmationPresentation.matches(item) {
            DocGroupConfirmationCard(
                item: item,
                observedSenders: viewModel.observedGroupSenders(for: item.docId),
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) }
            )
        } else if item.register == .waiting {
            DocWaitingItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                activeAnswerItemId: $viewModel.activeAnswerItemId,
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) }
            )
        } else if item.register == .draft {
            DocDraftItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                onOpen: { viewModel.presentDraft(item, composerScope: composerScope) },
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) }
            )
        } else {
            DocAskItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                activeAnswerItemId: $viewModel.activeAnswerItemId,
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) },
                onPhoto: { viewModel.addPendingPhoto($0, in: composerScope) }
            )
        }
    }

    private func rank(_ register: DocWaitingItem.Register) -> Int {
        switch register {
        case .waiting: 0
        case .draft: 1
        case .ask: 2
        }
    }
}

struct DocSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}
