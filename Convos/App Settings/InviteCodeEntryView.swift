import ConvosCore
import SwiftUI

struct InviteCodeAlertModifier: ViewModifier {
    let session: any SessionManagerProtocol
    @Binding var isPresented: Bool
    let onUnlocked: () -> Void

    @State private var code: String = ""
    @State private var isRedeeming: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false

    func body(content: Content) -> some View {
        content
            .alert("Assistants are rolling out", isPresented: $isPresented) {
                TextField("Rollout code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("invite-code-text-field")

                Button("Cancel", role: .cancel) {}

                Button("Continue") {
                    Task { await submit() }
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRedeeming)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("invite-code-submit-button")
            } message: {
                Text("Please enter your rollout code below to enable Assistants.")
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {
                    code = ""
                    isPresented = true
                }
            } message: {
                Text(errorMessage ?? "Something went wrong, try again")
            }
    }

    private func submit() async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRedeeming else { return }

        isRedeeming = true
        defer { isRedeeming = false }

        do {
            try await session.redeemInviteCode(trimmed)
            await MainActor.run {
                GlobalConvoDefaults.shared.assistantCodeUnlocked = true
                code = ""
                onUnlocked()
            }
        } catch let error as APIError {
            await MainActor.run {
                switch error {
                case .inviteCodeNotFound:
                    errorMessage = "No invite code found with that value"
                case .inviteCodeInvalidFormat:
                    errorMessage = "Code must be 8 letters"
                case .rateLimitExceeded:
                    errorMessage = "Too many attempts, try again later"
                default:
                    errorMessage = "Something went wrong, try again"
                }
                showingError = true
            }
        } catch {
            await MainActor.run {
                errorMessage = "Something went wrong, try again"
                showingError = true
            }
        }
    }
}

extension View {
    func inviteCodeAlert(
        isPresented: Binding<Bool>,
        session: any SessionManagerProtocol,
        onUnlocked: @escaping () -> Void
    ) -> some View {
        modifier(InviteCodeAlertModifier(
            session: session,
            isPresented: isPresented,
            onUnlocked: onUnlocked
        ))
    }
}
