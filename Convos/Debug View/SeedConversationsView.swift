import ConvosCore
import SwiftUI

@MainActor
@Observable
final class SeedConversationsViewModel {
    var isSeeding: Bool = false
    var progress: Int = 0
    var total: Int = 0
    var errorMessage: String?
    var completed: Bool = false
    var selectedCount: Int = 5

    private let session: any SessionManagerProtocol

    let countOptions: [Int] = [3, 5, 10, 20]

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    func seed() {
        guard !isSeeding, let sessionManager = session as? SessionManager else { return }
        isSeeding = true
        progress = 0
        total = selectedCount
        errorMessage = nil
        completed = false

        Task {
            do {
                _ = try await sessionManager.seedConversations(
                    count: selectedCount,
                    domain: ConfigManager.shared.associatedDomain
                ) { [weak self] count in
                    Task { @MainActor in
                        self?.progress = count
                    }
                }
                completed = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSeeding = false
        }
    }
}

struct SeedConversationsView: View {
    @State private var viewModel: SeedConversationsViewModel

    init(session: any SessionManagerProtocol) {
        _viewModel = State(initialValue: SeedConversationsViewModel(session: session))
    }

    var body: some View {
        Section("QA Seed Data") {
            Picker("Conversations", selection: $viewModel.selectedCount) {
                ForEach(viewModel.countOptions, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .accessibilityIdentifier("seed-conversations-count-picker")
            .disabled(viewModel.isSeeding)

            Button {
                viewModel.seed()
            } label: {
                HStack {
                    Text("Seed Conversations")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if viewModel.isSeeding {
                        HStack(spacing: 6) {
                            Text("\(viewModel.progress)/\(viewModel.total)")
                                .foregroundStyle(.colorTextSecondary)
                                .font(.footnote.monospacedDigit())
                            ProgressView()
                        }
                    } else if viewModel.completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("seed-completed-checkmark")
                    }
                }
            }
            .accessibilityIdentifier("seed-conversations-button")
            .disabled(viewModel.isSeeding)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
