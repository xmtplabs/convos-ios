import SwiftUI

struct ComponentShowcase<Content: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                CodeNameLabel(title)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            ComponentShowcase("ExampleButton", description: "A sample button component") {
                Button("Tap Me") {}
                    .buttonStyle(.borderedProminent)
            }

            ComponentShowcase("AnotherComponent") {
                Text("Component content here")
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
