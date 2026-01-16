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

                        VStack(alignment: .leading) {
                            Text(member.profile.displayName)
                                .font(.body)
                            Text("Role: \(member.role.rawValue), isCurrentUser: \(member.isCurrentUser)")
                                .font(.caption2)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.conversation.membersCountString)
    }
}

#Preview {
    ConversationMembersListView(viewModel: .mock)
}
