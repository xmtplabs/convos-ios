import SwiftUI

struct ErrorView: View {
    let error: Error
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .center, spacing: DesignConstants.Spacing.step4x) {
            Text(error.localizedDescription)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)

            if let onRetry {
                VStack(spacing: DesignConstants.Spacing.step2x) {
                    Button {
                        onRetry()
                    } label: {
                        Text("Retry")
                    }
                    .convosButtonStyle(.text)
                    .accessibilityIdentifier("retry-button")
                }
                .padding(.top, DesignConstants.Spacing.step4x)
            }
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
    }
}

private enum ErrorViewError: Error, LocalizedError {
    case testError
}

#Preview {
    ErrorView(error: ErrorViewError.testError) {}
}

#Preview {
    ErrorView(error: ErrorViewError.testError, onRetry: nil)
}
