import SwiftUI
import UIKit

/// A read-only row for a sensitive identity correlator (eth address, accountId,
/// inboxId, installation id, APNs token). The value is masked by default; a tap
/// reveals the full value in monospace, and an explicit copy button places it on
/// the clipboard. Masking-by-default plus explicit reveal is the accepted
/// control for surfacing these correlators in production.
struct DebugRevealableValueRow: View {
    let label: String
    let value: String?

    @State private var isRevealed: Bool = false
    @State private var didCopy: Bool = false

    private var displayValue: String {
        guard let value, !value.isEmpty else { return "(none)" }
        if isRevealed { return value }
        return Self.masked(value)
    }

    private var hasValue: Bool {
        guard let value else { return false }
        return !value.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundStyle(.colorTextPrimary)
            HStack(spacing: 8) {
                let toggleReveal = {
                    guard hasValue else { return }
                    isRevealed.toggle()
                }
                Button(action: toggleReveal) {
                    Text(displayValue)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(isRevealed ? nil : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .buttonStyle(.plain)
                .disabled(!hasValue)

                let copyValue: () -> Void = {
                    guard let value, !value.isEmpty else { return }
                    UIPasteboard.general.string = value
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                }
                Button(action: copyValue) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(!hasValue)
            }
        }
    }

    private static func masked(_ value: String) -> String {
        guard value.count > 10 else { return String(repeating: "•", count: value.count) }
        let prefix = value.prefix(6)
        let suffix = value.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
