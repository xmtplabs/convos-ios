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

                        Text(member.profile.displayName)
                            .font(.body)
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
