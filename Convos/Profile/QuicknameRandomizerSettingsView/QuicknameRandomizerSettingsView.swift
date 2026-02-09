import SwiftUI

struct QuicknameRandomizerSettingsView: View {
    @Bindable var quicknameSettings: QuicknameSettingsViewModel
    @State private var tagsViewModel: TagsFieldViewModel
    @FocusState private var textFieldFocused: Bool

    init(
        quicknameSettings: QuicknameSettingsViewModel
    ) {
        self.quicknameSettings = quicknameSettings
        _tagsViewModel = State(initialValue: .init(tags: quicknameSettings.tags))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(quicknameSettings.exampleDisplayName, text: $quicknameSettings.exampleDisplayName)
                            .disabled(true)

                        Button {
                        } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
//                    HStack {
//                        Text("Randomizer")
//                            .foregroundStyle(.colorTextSecondary)
//                        Spacer()
//                    }
                } footer: {
                    Text("Name generation is done on-device only. Try out different keywords to use.")
                        .foregroundStyle(.colorTextSecondary)
                }

                Section {
                    TagsField(
                        viewModel: tagsViewModel,
                        currentText: $tagsViewModel.currentText,
                        isTextFieldFocused: $textFieldFocused,
                        selectedTag: $tagsViewModel.selectedTag
                    )
                    .listRowBackground(Color.clear)
                    .onChange(of: tagsViewModel.tags) {
                        quicknameSettings.tags = tagsViewModel.tags
                    }
                }
                .listRowSeparator(.hidden)
                .listRowSpacing(0.0)
                .listRowInsets(.all, DesignConstants.Spacing.step2x)
                .listSectionMargins(.top, 0.0)
                .listSectionSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
        }
        .navigationTitle("Randomizer")
    }
}

#Preview {
    @Previewable @State var viewModel: QuicknameSettingsViewModel = .shared
    QuicknameRandomizerSettingsView(quicknameSettings: viewModel)
}
