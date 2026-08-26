import ConvosCore
import SwiftUI

struct DocForYouSection: View {
    @Bindable var viewModel: DocExperienceViewModel
    let items: [DocWaitingItem]
    let composerScope: DocComposerScope

    @State private var isExpanded: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        Section {
            ForEach(visibleItems) { item in
                itemCard(for: item)
                    .transition(DocMotion.itemTransition(reduceMotion: reduceMotion))
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if hiddenCount > 0 || isExpanded {
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
                .foregroundStyle(Color.accentColor)
                .listRowInsets(rowInsets)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("doc-for-you-more")
            }
        } header: {
            Text("For you")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
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
        isExpanded ? rankedItems : Array(rankedItems.prefix(3))
    }

    private var hiddenCount: Int {
        max(0, rankedItems.count - 3)
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
        switch item.register {
        case .waiting:
            DocWaitingItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                activeAnswerItemId: $viewModel.activeAnswerItemId,
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) }
            )
        case .draft:
            DocDraftItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                onOpen: { viewModel.presentDraft(item) },
                onAnswer: { viewModel.sendAnswer($0, for: item) },
                onRetry: { viewModel.retryAnswer(for: item) }
            )
        case .ask:
            DocAskItemCard(
                item: item,
                sendState: viewModel.sendState(for: item),
                isEnabled: viewModel.isDmReadyForDisplay,
                activeAnswerItemId: $viewModel.activeAnswerItemId,
                onShareNumber: { viewModel.presentShareNumber(for: item) },
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
