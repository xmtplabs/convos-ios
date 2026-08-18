import AVFoundation
import ConvosComposer
import SwiftUI

/// Reading someone else's code. The twin of `InviteCodeSheet`: same card
/// column, same single chrome, one job each - that one shows this
/// conversation's code, this one reads another.
struct JoinConversationView: View {
    @Bindable var viewModel: QRScannerViewModel
    let allowsDismissal: Bool
    let onScannedCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            ScannerCard(onScannedCode: attemptToScanCode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.colorBackgroundSurfaceless)
                .navigationTitle("Scan a code")
                .navigationBarTitleDisplayMode(.inline)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .toolbar {
                    if allowsDismissal {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) {
                                dismiss()
                            }
                            .accessibilityIdentifier("scanner-close-button")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if let code = UIPasteboard.general.string {
                                attemptToScanCode(code)
                            }
                        } label: {
                            Image(systemName: "clipboard")
                        }
                        .accessibilityLabel("Paste invite code from clipboard")
                        .accessibilityIdentifier("paste-invite-button")
                    }
                }
                .alert("This is not a convo", isPresented: $viewModel.showInvalidInviteCodeFormat) {
                    Button("Try again") {
                        viewModel.showInvalidInviteCodeFormat = false
                    }
                    .buttonStyle(.glassProminent)
                } message: {
                    if let failedCode = viewModel.invalidInviteCode {
                        Text(failedCode)
                    }
                }
        }
    }

    private func attemptToScanCode(_ code: String) {
        onScannedCode(code)
    }
}

#Preview {
    JoinConversationView(viewModel: .init(), allowsDismissal: true, onScannedCode: { _ in
    })
}
