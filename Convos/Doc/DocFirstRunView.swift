import ConvosCore
import SwiftUI

enum DocFirstRunStep: Equatable {
    case welcome
    case verify
    case connectGoogle
    case home
}

enum DocFirstRunReducer {
    static func step(
        hasCompletedWelcome: Bool,
        hasCompletedFirstRun: Bool,
        hasVerifiedNumber: Bool,
        hasGrantedGoogleDocs: Bool
    ) -> DocFirstRunStep {
        if hasCompletedFirstRun { return .home }
        if !hasCompletedWelcome { return .welcome }
        if !hasVerifiedNumber { return .verify }
        if !hasGrantedGoogleDocs { return .connectGoogle }
        return .home
    }
}

struct DocWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "doc.text.fill",
            title: "Your group talks. I keep the doc current.",
            message: "Start with screenshots or start in iMessage."
        ) {
            DocWelcomeTeaching()
        } action: {
            Button("Continue", action: onContinue)
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
                .accessibilityIdentifier("doc-welcome-continue")
        }
        .accessibilityIdentifier("doc-welcome")
    }
}

private struct DocWelcomeTeaching: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            teachingRow(
                systemImage: "photo.on.rectangle.angled",
                title: "Send screenshots",
                detail: "I'll turn them into the first doc."
            )
            teachingRow(
                systemImage: "bubble.left.and.bubble.right.fill",
                title: "Add @doc to a group",
                detail: "The first new text starts the doc."
            )
            Text("Connect later anytime—standalone docs work too.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func teachingRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .frame(width: 36.0, height: 36.0)
                .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 10.0))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DocVerifyFirstRunView: View {
    let verification: DocControlVerification?
    let startupErrorMessage: String?
    let onRenew: () -> Void
    let onRetryStartup: () -> Void

    @State private var isWaitingForText: Bool = false

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "message.fill",
            title: "Verify your number",
            message: "Your number is how @doc knows you. Texting from a group connects that group to your doc."
        ) {
            verificationIdentity
        } action: {
            actionContent
        }
        .accessibilityIdentifier("doc-first-run-verify")
    }

    @ViewBuilder
    private var verificationIdentity: some View {
        if let verification {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text("@doc")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(docDisplayPhoneNumber(verification.lineNumber))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.colorTextSecondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Text @doc at \(verification.lineNumber)")
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if isWaitingForText {
                Label("Waiting for your text…", systemImage: "ellipsis.message")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .transition(.opacity)
                    .accessibilityIdentifier("doc-first-run-verify-waiting")
            }

            if let startupErrorMessage, verification == nil {
                Text(startupErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onRetryStartup)
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
            } else if let verification {
                verificationAction(for: verification)
            } else {
                ProgressView("Getting your number ready…")
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("doc-first-run-verify-preparing")
            }
        }
    }

    @ViewBuilder
    private func verificationAction(for verification: DocControlVerification) -> some View {
        if verification.status == .expired {
            Button("Get a new code", action: onRenew)
                .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
        } else {
            DocVerificationActionButton(
                verification: verification,
                isWaitingForText: $isWaitingForText
            )
        }
    }
}

struct DocGoogleFirstRunView: View {
    let isConnecting: Bool
    let isWaitingForApproval: Bool
    let canConnect: Bool
    let errorMessage: String?
    let startupErrorMessage: String?
    let onConnect: () -> Void
    let onRetryStartup: () -> Void

    var body: some View {
        DocFirstRunScaffold(
            systemImage: "doc.text.fill",
            title: "Connect Google",
            message: "Your doc lives in your Google account, where it stays yours to open and share."
        ) {
            EmptyView()
        } action: {
            actionContent
        }
        .accessibilityIdentifier("doc-first-run-google")
    }

    private var actionContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if isWaitingForApproval {
                Label("Waiting for approval…", systemImage: "ellipsis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .accessibilityIdentifier("doc-first-run-google-waiting")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("doc-first-run-google-error")
            } else if let startupErrorMessage, !canConnect {
                Text(startupErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if startupErrorMessage != nil, !canConnect {
                Button("Try again", action: onRetryStartup)
                    .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
            } else {
                connectButton
            }
        }
    }

    private var connectButton: some View {
        Button(action: onConnect) {
            if isConnecting {
                ProgressView()
                    .tint(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Connecting Google")
            } else {
                Text(errorMessage == nil ? "Connect Google" : "Try again")
            }
        }
        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
        .frame(minHeight: 44.0)
        .disabled(!canConnect || isConnecting)
        .accessibilityIdentifier("doc-first-run-google-connect")
    }
}

private struct DocFirstRunScaffold<Details: View, Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let details: Details
    let action: Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.details = details()
        self.action = action()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: DesignConstants.Spacing.step8x)
                    Image(systemName: systemImage)
                        .font(.system(size: 56.0, weight: .medium))
                        .foregroundStyle(.colorLava)
                        .frame(width: 96.0, height: 96.0)
                        .background(
                            .colorFillMinimal,
                            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                        )
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.colorTextPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step6x)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)

                    Text(message)
                        .font(.title3)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step3x)
                        .padding(.horizontal, DesignConstants.Spacing.step8x)

                    details
                        .frame(maxWidth: Constant.maximumTextWidth)
                        .padding(.top, DesignConstants.Spacing.step5x)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)

                    Spacer(minLength: DesignConstants.Spacing.step8x)

                    action
                        .frame(maxWidth: Constant.maximumActionWidth)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)
                        .padding(.bottom, DesignConstants.Spacing.step6x)
                }
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Color.colorBackgroundSurfaceless)
    }
}

private enum Constant {
    static let maximumTextWidth: CGFloat = 560.0
    static let maximumActionWidth: CGFloat = 440.0
}
