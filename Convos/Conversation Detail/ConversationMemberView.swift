import ConvosCore
import SwiftUI

struct ConversationMemberView: View {
    @Bindable var viewModel: ConversationViewModel
    let member: ConversationMember

    @State private var presentingBlockConfirmation: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

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

            if member.isAgent && member.profile.isOutOfCredits {
                Section {
                    let url = URL(string: "https://learn.convos.org/assistants-processing-power")
                    let action = { if let url { openURL(url) } }
                    Button(action: action) {
                        HStack {
                            Image(systemName: "battery.0percent")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.colorRed, in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("No Power")
                                    .font(.body)
                                    .foregroundStyle(.colorTextPrimary)
                                Text("Paused indefinitely")
                                    .font(.subheadline)
                                    .foregroundStyle(.colorRed)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(.colorFillTertiary)
                        }
                    }
                } footer: {
                    Text("Assistants require processing power")
                }
            }

            if !member.isCurrentUser {
                Section {
                    Button {
                        presentingBlockConfirmation = true
                    } label: {
                        Text("Block")
                            .foregroundStyle(.colorCaution)
                    }
                    .accessibilityLabel("Block \(member.profile.displayName)")
                    .accessibilityIdentifier("block-member-button")
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
                        .accessibilityLabel("Remove \(member.profile.displayName)")
                        .accessibilityIdentifier("remove-member-button")
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
