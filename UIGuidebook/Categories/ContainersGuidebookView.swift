import SwiftUI

struct ContainersGuidebookView: View {
    @State private var flowLayoutItems: [String] = ["Swift", "SwiftUI", "UIKit", "Combine", "Async/Await", "CoreData"]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                flowLayoutSection
                infoViewSection
                maxedOutInfoViewSection
                primarySecondaryContainerSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var flowLayoutSection: some View {
        ComponentShowcase(
            "FlowLayout",
            description: "Custom Layout that wraps children to new lines when they exceed available width"
        ) {
            VStack(spacing: 16) {
                FlowLayout(spacing: 8) {
                    ForEach(flowLayoutItems, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.colorFillSecondary)
                            )
                    }
                }

                Divider()

                Text("Add more items to see wrapping:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let addAction = {
                    flowLayoutItems.append("New \(flowLayoutItems.count + 1)")
                }
                let resetAction = {
                    flowLayoutItems = ["Swift", "SwiftUI", "UIKit"]
                }
                HStack {
                    Button("Add Item", action: addAction)
                        .buttonStyle(.bordered)
                    Button("Reset", action: resetAction)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var infoViewSection: some View {
        ComponentShowcase(
            "InfoView",
            description: "Standard information sheet with title, description, and dismiss button"
        ) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Invalid invite")
                        .font(.system(.title2))
                        .fontWeight(.bold)
                    Text("Looks like this invite isn't active anymore.")
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)

                    Button("Got it") {}
                        .convosButtonStyle(.rounded(fullWidth: true))
                        .padding(.top, 8)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.quaternary, lineWidth: 1)
                )

                Text("Full component: InfoView(title:description:onDismiss:)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var maxedOutInfoViewSection: some View {
        ComponentShowcase(
            "MaxedOutInfoView",
            description: "Specialized InfoView shown when conversation limit is reached"
        ) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Maxed out")
                        .font(.system(.title2))
                        .fontWeight(.bold)
                    Text("The app currently supports up to 20 convos. Consider exploding some to make room for new ones.")
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)

                    Button("Got it") {}
                        .convosButtonStyle(.rounded(fullWidth: true))
                        .padding(.top, 8)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.quaternary, lineWidth: 1)
                )

                Text("Usage: MaxedOutInfoView(maxNumberOfConvos: Int)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primarySecondaryContainerSection: some View {
        ComponentShowcase(
            "PrimarySecondaryContainerView",
            description: "Animatable container that morphs between primary and secondary content with blur transitions"
        ) {
            VStack(spacing: 16) {
                Text("This component creates smooth transitions between two views with configurable corner radii, padding, and glass effects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Animatable progress (0.0 to 1.0)", systemImage: "slider.horizontal.3")
                    Label("Configurable corner radius per state", systemImage: "square.on.square")
                    Label("Blur transition during morph", systemImage: "wand.and.stars")
                    Label("Glass effect support", systemImage: "rectangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Requires ConvosCore for full demo. Used in conversation toolbar for expand/collapse animations.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ContainersGuidebookView()
            .navigationTitle("Containers")
    }
}
