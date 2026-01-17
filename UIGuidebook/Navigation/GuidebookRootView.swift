import SwiftUI

struct GuidebookRootView: View {
    @State private var selectedCategory: ComponentCategory?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(ComponentCategory.allCases, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.rawValue)
                                .font(.headline)
                            Text(category.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("UI Guidebook")
        } detail: {
            if let category = selectedCategory {
                category.destinationView
                    .navigationTitle(category.rawValue)
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "square.grid.2x2",
                    description: Text("Choose a component category from the sidebar to explore UI components")
                )
            }
        }
    }
}

#Preview {
    GuidebookRootView()
}
