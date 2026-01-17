import SwiftUI

struct TextInputsGuidebookView: View {
    @State private var labeledText: String = ""
    @State private var backspaceText: String = ""
    @State private var backspaceEditingEnabled: Bool = true
    @FocusState private var labeledFieldFocused: Bool
    @FocusState private var backspaceFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                labeledTextFieldSection
                backspaceTextFieldSection
                flowLayoutTextEditorSection
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var labeledTextFieldSection: some View {
        ComponentShowcase(
            "LabeledTextField",
            description: "Text field with a label above and customizable border color"
        ) {
            VStack(spacing: 16) {
                LabeledTextField(
                    label: "Name",
                    prompt: "Enter your name",
                    textFieldBorderColor: .colorBorderSubtle,
                    text: $labeledText,
                    isFocused: $labeledFieldFocused
                )

                LabeledTextField(
                    label: "Email",
                    prompt: "email@example.com",
                    textFieldBorderColor: .colorBorderSubtle2,
                    text: .constant(""),
                    isFocused: $labeledFieldFocused
                )

                Text("With colored border:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LabeledTextField(
                    label: "Username",
                    prompt: "Choose a username",
                    textFieldBorderColor: .colorOrange,
                    text: .constant(""),
                    isFocused: $labeledFieldFocused
                )
            }
        }
    }

    private var backspaceTextFieldSection: some View {
        ComponentShowcase(
            "BackspaceTextField",
            description: "Text field that detects backspace on empty input. Useful for tag/chip inputs."
        ) {
            VStack(spacing: 16) {
                HStack {
                    BackspaceTextField(
                        text: $backspaceText,
                        editingEnabled: $backspaceEditingEnabled,
                        onBackspaceWhenEmpty: {
                            print("Backspace pressed when empty!")
                        },
                        onEndedEditing: {
                            print("Ended editing")
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                    )
                }

                Text("Try pressing backspace when empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var flowLayoutTextEditorSection: some View {
        ComponentShowcase(
            "FlowLayoutTextEditor",
            description: "Combines BackspaceTextField with FlowLayout for chip-based inputs with backspace navigation"
        ) {
            VStack(spacing: 12) {
                Text("This component integrates with FlowLayout for tag-based inputs. See the FlowLayout section for a complete example.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    ForEach(["Tag 1", "Tag 2", "Tag 3"], id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(.colorFillSecondary)
                            )
                    }
                    Text("Type here...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TextInputsGuidebookView()
            .navigationTitle("Text Inputs")
    }
}
