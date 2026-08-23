import SwiftUI

/// Debug surface for the conversation's Space web URL. The Assistant Worker
/// is the value's normal authority; this screen lets an engineer overwrite it
/// (e.g. with a local or ngrok page while testing the window.convos bridge)
/// or clear it back to the waiting state. The worker may replace the override
/// on its next publish.
struct SpaceURLDebugView: View {
    private let currentURLString: () -> String?
    private let updateSpaceURL: (_ urlString: String?) async throws -> Void

    @State private var urlInput: String = ""
    @State private var currentValue: String?
    @State private var actionStatus: String?
    @State private var isUpdating: Bool = false

    init(
        currentURLString: @escaping () -> String?,
        updateSpaceURL: @escaping (_ urlString: String?) async throws -> Void
    ) {
        self.currentURLString = currentURLString
        self.updateSpaceURL = updateSpaceURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16.0) {
                currentValueSection
                Divider()
                controls
            }
            .padding()
        }
        .navigationTitle("Space URL")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            currentValue = currentURLString()
            urlInput = currentValue ?? ""
        }
    }

    @ViewBuilder
    private var currentValueSection: some View {
        VStack(alignment: .leading, spacing: 8.0) {
            Text("Current value")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
            Text(currentValue ?? "none published")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8.0) {
            Text("Override")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
            TextField("https://…", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            HStack(spacing: 12.0) {
                Button {
                    update(clearing: false)
                } label: {
                    Text("Update")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpdating || !isInputValid)
                Button {
                    update(clearing: true)
                } label: {
                    Text("Clear")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isUpdating)
            }
            if let actionStatus {
                Text(actionStatus)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A non-empty input must at least parse as an http(s) URL before the
    /// override can be written; the home surface refuses other schemes anyway.
    private var isInputValid: Bool {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    @MainActor
    private func update(clearing: Bool) {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = clearing ? nil : trimmed
        Task {
            isUpdating = true
            actionStatus = clearing ? "Clearing…" : "Updating…"
            do {
                try await updateSpaceURL(newValue)
                currentValue = currentURLString()
                actionStatus = clearing ? "Cleared." : "Updated."
                if clearing {
                    urlInput = ""
                }
            } catch {
                actionStatus = "Failed: \(error.localizedDescription)"
            }
            isUpdating = false
        }
    }
}

#Preview {
    NavigationStack {
        SpaceURLDebugView(
            currentURLString: { "https://spaces.convos.org/preview" },
            updateSpaceURL: { _ in }
        )
    }
}
