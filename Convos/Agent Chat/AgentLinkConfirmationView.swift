import ConvosCore
import SwiftUI

struct AgentLinkConfirmationView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    private var host: String {
        url.host(percentEncoded: false) ?? "Unknown host"
    }

    private var canOpen: Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                Image(systemName: "safari")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Open this link?")
                    .font(.title2.weight(.semibold))
                Text(host)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("This address came from your agent. Check the host before leaving Convos.")
                    .foregroundStyle(.secondary)
                Spacer()
                openButton
            }
            .padding(DesignConstants.Spacing.step4x)
            .navigationTitle("External link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private var openButton: some View {
        let action = {
            guard canOpen else { return }
            openURL(url)
            dismiss()
        }
        return Button("Open \(host)", action: action)
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .frame(maxWidth: .infinity)
            .disabled(!canOpen)
    }
}
