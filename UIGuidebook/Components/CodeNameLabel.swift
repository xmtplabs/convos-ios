import SwiftUI

struct CodeNameLabel: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Text(name)
            .font(.system(.subheadline, design: .monospaced))
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            )
    }
}

#Preview {
    VStack(spacing: 20) {
        CodeNameLabel("RoundedButtonStyle")
        CodeNameLabel("OutlineButtonStyle")
        CodeNameLabel("HoldToConfirmButton")
        CodeNameLabel("LabeledTextField")
    }
    .padding()
}
