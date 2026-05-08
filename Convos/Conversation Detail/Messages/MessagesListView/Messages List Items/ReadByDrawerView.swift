import ConvosCore
import SwiftUI

struct ReadByDrawerView: View {
    let members: [ConversationMember]

    private var sortedMembers: [ConversationMember] {
        members.sorted { lhs, rhs in
            if lhs.isCurrentUser && !rhs.isCurrentUser { return true }
            if !lhs.isCurrentUser && rhs.isCurrentUser { return false }
            return lhs.profile.displayName.localizedCaseInsensitiveCompare(rhs.profile.displayName)
                == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Read by")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .padding(.bottom, DesignConstants.Spacing.step2x)

            BoundedScrollView(maxHeight: 600.0) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                    ForEach(sortedMembers, id: \.self) { member in
                        ReadByRowView(member: member)
                    }
                }
            }
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
    }
}

private struct ReadByRowView: View {
    let member: ConversationMember

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ProfileAvatarView(
                profile: member.profile,
                profileImage: nil,
                useSystemPlaceholder: false,
                agentVerification: member.agentVerification
            )
            .frame(width: 40.0, height: 40.0)

            Text(member.isCurrentUser ? "You" : member.profile.displayName.capitalized)
                .font(.callout)
                .foregroundStyle(.colorTextPrimary)

            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.isCurrentUser ? "You" : member.profile.displayName) read this message")
    }
}

#Preview {
    @Previewable @State var presenting: Bool = false

    let members: [ConversationMember] = [
        .mock(name: "Alice"),
        .mock(name: "Convos Assistant", isAgent: true, agentVerification: .verified(.convos)),
        .mock(name: "Bob"),
        .mock(name: "OAuth Agent", isAgent: true, agentVerification: .verified(.userOAuth))
    ]

    VStack {
        let action = { presenting.toggle() }
        Button(action: action) {
            Text("Show Read by")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        ReadByDrawerView(members: members)
    }
}
