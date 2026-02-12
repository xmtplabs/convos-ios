import ConvosCore
import SwiftUI

struct ConversationMembersListView: View {
    @Bindable var viewModel: ConversationViewModel

    var body: some View {
        List {
            ForEach(viewModel.conversation.members.sortedByRole(), id: \.id) { member in
                NavigationLink {
                    ConversationMemberView(viewModel: viewModel, member: member)
                } label: {
                    HStack {
                        ProfileAvatarView(profile: member.profile, profileImage: nil, useSystemPlaceholder: false)
                            .frame(width: DesignConstants.ImageSizes.mediumAvatar, height: DesignConstants.ImageSizes.mediumAvatar)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text(member.profile.displayName)
                                .font(.body)
                            if member.isCurrentUser {
                                Text("You")
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                            } else if member.role == .superAdmin {
                                Text("Owner")
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("member-\(member.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle(viewModel.conversation.membersCountString)
    }
}

#Preview {
    ConversationMembersListView(viewModel: .mock)
}
