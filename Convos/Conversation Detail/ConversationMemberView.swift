import ConvosCore
import SwiftUI

struct ConversationMemberView: View {
    @Bindable var viewModel: ConversationViewModel
    let member: ConversationMember

    @State private var presentingBlockConfirmation: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack {
                        ProfileAvatarView(profile: member.profile, profileImage: nil, useSystemPlaceholder: false)
                            .frame(width: 160.0, height: 160.0)

                        Text(member.profile.displayName.capitalized)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                            .foregroundStyle(.colorTextPrimary)

                        if member.isCurrentUser {
                            Text("You")
                                .font(.headline)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            .listSectionMargins(.top, 0.0)
            .listSectionSeparator(.hidden)

            if !member.isCurrentUser {
                Section {
                    Button {
                        presentingBlockConfirmation = true
                    } label: {
                        Text("Block")
                            .foregroundStyle(.colorCaution)
                    }
                    .confirmationDialog("", isPresented: $presentingBlockConfirmation) {
                        Button("Block and leave", role: .destructive) {
                            viewModel.leaveConvo()
                        }

                        Button(role: .cancel) {
                            presentingBlockConfirmation = false
                        }
                    }
                } footer: {
                    Text("Block \(member.profile.displayName.capitalized) and leave the convo")
                        .foregroundStyle(.colorTextSecondary)
                }

                if viewModel.canRemoveMembers {
                    Section {
                        Button {
                            viewModel.remove(member: member)
                            dismiss()
                        } label: {
                            Text("Remove")
                                .foregroundStyle(.colorTextSecondary)
                        }
                    } footer: {
                        Text("Remove \(member.profile.displayName.capitalized) from the convo")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }
}

#Preview {
    ConversationMemberView(viewModel: .mock, member: .mock())
}
