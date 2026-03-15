import SwiftUI

struct FlowLayoutTextEditor: View {
    @Binding var text: String
    @Binding var editingEnabled: Bool
    var isFocused: FocusState<Bool>.Binding
    let maxTextFieldWidth: CGFloat
    let minTextFieldWidth: CGFloat = 75.0
    let onBackspaceWhenEmpty: () -> Void
    let onReturn: () -> Void
    let onEndedEditing: () -> Void

    var body: some View {
        Group {
            BackspaceTextField(
                text: $text,
                editingEnabled: $editingEnabled,
                onBackspaceWhenEmpty: onBackspaceWhenEmpty,
                onReturn: onReturn,
                onEndedEditing: onEndedEditing
            )
            .padding(.horizontal, 10.0)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .frame(maxWidth: maxTextFieldWidth)
            .focused(isFocused.projectedValue)
            .offset(y: 0.0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: minTextFieldWidth, alignment: .leading)
        .clipped()
        .onAppear {
            isFocused.wrappedValue = true
        }
        .onTapGesture {
            isFocused.wrappedValue = true
        }
    }
}

private struct FlowLayoutTextEditorExample: View {
    let maxHeight: CGFloat = 150.0

    @FocusState var isFocused: Bool
    @State var searchText: String = ""
    @State var editingEnabled: Bool = true
    @State var selectedItem: String? {
        didSet {
            editingEnabled = selectedItem == nil
        }
    }
    @State var items: [String] = [
        "Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Cameron", "Skylar",
        "Emerson", "Quinn", "Avery", "Hayden", "Rowan", "Sage", "Finley", "Dakota",
        "Madison", "Reese", "Logan", "Phoenix", "Artemis", "VeryLongNameThatWillWrapNicely",
        "VeryLongNameThatWillNotFitInTheWidthOfTheEntireViewAndWillTruncate",
        "John"
    ]

    func selected(item: String) {
        selectedItem = selectedItem == item ? nil : item
    }

    func backspaceOnEmpty() {
        if let selectedItem {
            items.removeAll { $0 == selectedItem }
            self.selectedItem = nil
        } else {
            selectedItem = items.last
        }
    }

    private func chipLabel(for item: String) -> some View {
        let isItemSelected: Bool = item == selectedItem
        let textColor: Color = isItemSelected ? .colorTextPrimaryInverted : .colorTextPrimary
        let bgColor: Color = isItemSelected ? .colorBackgroundInverted : .gray.opacity(0.2)
        return Text(item)
            .foregroundStyle(textColor)
            .padding(DesignConstants.Spacing.step2x)
            .background(bgColor)
            .cornerRadius(DesignConstants.CornerRadius.small)
    }

    var body: some View {
        GeometryReader { reader in
            ScrollView {
                FlowLayout(spacing: DesignConstants.Spacing.step2x) {
                    ForEach(items, id: \.self) { item in
                        chipLabel(for: item)
                    }

                    FlowLayoutTextEditor(
                        text: $searchText,
                        editingEnabled: $editingEnabled,
                        isFocused: $isFocused,
                        maxTextFieldWidth: reader.size.width,
                        onBackspaceWhenEmpty: {
                            backspaceOnEmpty()
                        },
                        onReturn: {
                        },
                        onEndedEditing: {
                        }
                    )
                    .opacity(selectedItem != nil ? 0.0 : 1.0)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxHeight)
        }
        .frame(maxHeight: maxHeight)
        .onAppear {
            isFocused = true
        }
    }
}

#Preview {
    VStack {
        HStack {
            Spacer().frame(width: 40.0)
            FlowLayoutTextEditorExample()
            Spacer().frame(width: 40.0)
        }
        Spacer()
    }
}
