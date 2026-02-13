import SwiftUI

// MARK: - View Extension

extension View {
    /// Presents a sheet that automatically sizes itself to fit its content
    /// - Parameters:
    ///   - isPresented: A binding to whether the sheet is shown
    ///   - content: The content of the sheet
    func selfSizingSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(SelfSizingSheetModifier(
            isPresented: isPresented,
            onDismiss: nil,
            sheetContent: content
        ))
    }
}

// MARK: - Self-Sizing Sheet Modifier

/// A view modifier that presents a sheet that automatically sizes itself to its content
private struct SelfSizingSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @State private var sheetHeight: CGFloat = 0
    @State private var presentationCount: Int = 0
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent

    private static var sheetTopInset: CGFloat { 20.0 }

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: $isPresented,
                onDismiss: {
                    sheetHeight = 0
                    presentationCount += 1
                    onDismiss?()
                },
                content: {
                    sheetContent()
                        .fixedSize(horizontal: false, vertical: true)
                        .readHeight { height in
                            sheetHeight = height
                        }
                        .presentationDetents(sheetHeight > 0.0 ? [.height(sheetHeight + Self.sheetTopInset)] : [.medium])
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(.ultraThinMaterial)
                        .id(presentationCount)
                }
            )
    }
}

extension View {
    /// Presents a sheet that automatically sizes itself to fit its content, with an optional onDismiss callback
    /// - Parameters:
    ///   - isPresented: A binding to whether the sheet is shown
    ///   - onDismiss: Optional closure to execute when the sheet is dismissed
    ///   - content: The content of the sheet
    func selfSizingSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(SelfSizingSheetModifier(
            isPresented: isPresented,
            onDismiss: onDismiss,
            sheetContent: content
        ))
    }
}

// MARK: - Item-based presentation

/// A view modifier for presenting a self-sizing sheet based on an optional item
private struct ItemBasedSelfSizingSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    @State private var sheetHeight: CGFloat = 0
    @State private var presentationCount: Int = 0
    let onDismiss: (() -> Void)?
    let sheetContent: (Item) -> SheetContent

    private static var sheetTopInset: CGFloat { 20.0 }

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $item,
                onDismiss: {
                    sheetHeight = 0
                    presentationCount += 1
                    onDismiss?()
                }, content: { item in
                    sheetContent(item)
                        .fixedSize(horizontal: false, vertical: true)
                        .readHeight { height in
                            sheetHeight = height
                        }
                        .presentationDetents(sheetHeight > 0.0 ? [.height(sheetHeight + Self.sheetTopInset)] : [.medium])
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(.ultraThinMaterial)
                        .id(presentationCount)
                }
            )
    }
}

extension View {
    /// Presents a sheet that automatically sizes itself based on an identifiable item
    /// - Parameters:
    ///   - item: A binding to an optional identifiable item
    ///   - onDismiss: Optional closure to execute when the sheet is dismissed
    ///   - content: The content of the sheet, which receives the item
    func selfSizingSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(ItemBasedSelfSizingSheetModifier(
            item: item,
            onDismiss: onDismiss,
            sheetContent: content
        ))
    }
}

// MARK: - Preview

#Preview("Self-Sizing Sheet") {
    struct PreviewContent: View {
        @State private var showingSheet: Bool = false
        @State private var selectedItem: DemoItem?

        struct DemoItem: Identifiable {
            let id: UUID = UUID()
            let title: String
            let message: String
        }

        var body: some View {
            VStack(spacing: 20) {
                // Boolean-based presentation
                Button("Show Self-Sizing Sheet") {
                    showingSheet = true
                }
                .selfSizingSheet(isPresented: $showingSheet) {
                    VStack(spacing: 16) {
                        Text("Self-Sizing Content")
                            .font(.title)
                        Text("This sheet automatically adjusts its height to fit the content.")
                        Button("Dismiss") {
                            showingSheet = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }

                // Item-based presentation
                Button("Show Item Sheet") {
                    selectedItem = DemoItem(
                        title: "Dynamic Content",
                        message: "This sheet was presented with an item."
                    )
                }
                .selfSizingSheet(item: $selectedItem) { item in
                    VStack(spacing: 16) {
                        Text(item.title)
                            .font(.title2)
                        Text(item.message)
                            .foregroundColor(.secondary)
                        Button("Done") {
                            selectedItem = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
            }
            .padding()
        }
    }

    return PreviewContent()
}
