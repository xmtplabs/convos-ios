import ConvosCore
import PhotosUI
import SwiftUI

struct ConversationInfoEditView: View {
    @Bindable var viewModel: ConversationViewModel
    let focusCoordinator: FocusCoordinator

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isImagePickerPresented: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: DesignConstants.Spacing.step6x) {
                            ConversationAvatarView(
                                conversation: viewModel.conversation,
                                conversationImage: viewModel.conversationImage
                            )
                            .frame(width: 160.0, height: 160.0)

                            ImagePickerButton(
                                currentImage: $viewModel.conversationImage,
                                isPickerPresented: $isImagePickerPresented,
                                showsCurrentImage: false,
                                symbolSize: 20.0,
                                symbolName: "photo.fill.on.rectangle.fill"
                            )
                            .frame(width: 44.0, height: 44.0)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .listSectionMargins(.top, 0.0)
                .listSectionSeparator(.hidden)

                Section {
                    TextField(
                        viewModel.conversationNamePlaceholder,
                        text: $viewModel.editingConversationName
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 166.0)
                    .onAppear {
                        viewModel.isEditingConversationName = true
                    }
                    .onChange(of: viewModel.editingConversationName) { _, newValue in
                        if newValue.count > NameLimits.maxConversationNameLength {
                            viewModel.editingConversationName = String(newValue.prefix(NameLimits.maxConversationNameLength))
                        }
                    }

                    TextField(
                        viewModel.conversationDescriptionPlaceholder,
                        text: $viewModel.editingDescription
                    )
                    .lineLimit(5)
                    .onAppear {
                        viewModel.isEditingDescription = true
                    }
                }

                Section {
                    Toggle(isOn: $viewModel.includeInfoInPublicPreview) {
                        Text("Include info with invites")
                    }
                    .disabled(viewModel.isUpdatingPublicPreview)
                } footer: {
                    Text("When enabled, anyone with your convo code can see its pic, name and description")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundRaisedSecondary)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .cancel) {
                        viewModel.onConversationSettingsCancelled()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) {
                        viewModel.onConversationSettingsDismissed(focusCoordinator: focusCoordinator)
                    }
                    .tint(.colorBackgroundInverted)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    ConversationInfoEditView(viewModel: .mock, focusCoordinator: focusCoordinator)
}
