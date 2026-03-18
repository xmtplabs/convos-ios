import ConvosCore
import SwiftUI

struct ConversationMemberView: View {
    @Bindable var viewModel: ConversationViewModel
    let member: ConversationMember

    @State private var presentingBlockConfirmation: Bool = false
    @State private var provisioningService: AgentServiceType?
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    @State private var provisionedPhone: String?
    @State private var provisionedEmail: String?

    private var liveMember: ConversationMember {
        viewModel.conversation.members.first { $0.id == member.id } ?? member
    }

    var body: some View {
        List {
            profileHeaderSection
            if member.isAgent { aboutSection }
            if member.isAgent { toolsSection }
            if member.isAgent { learnMoreSection }
            if member.isAgent && member.profile.isOutOfCredits { outOfCreditsSection }
            if !member.isCurrentUser { blockSection }
            if !member.isCurrentUser && viewModel.canRemoveMembers { removeSection }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .task { await loadProvisionStatus() }
    }

    // MARK: - Sections

    private var profileHeaderSection: some View {
        Section {
            HStack {
                Spacer()
                VStack {
                    MessageAvatarView(profile: member.profile, size: 160.0, agentVerification: member.agentVerification)

                    Text(member.profile.displayName.capitalized)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(.colorTextPrimary)

                    if member.isCurrentUser {
                        Text("You")
                            .font(.headline)
                            .foregroundStyle(.colorTextSecondary)
                    } else if let subtitle = memberSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    private var aboutSection: some View {
        Section {
            Text("Hi! I learn by listening and speak up when I think I can help. Ask me anything, and I can often figure it out.")
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
        } footer: {
            Text("About me")
        }
    }

    private var toolsSection: some View {
        Section {
            emailToolRow
            toolRow(
                icon: "pointer.arrow",
                color: .colorInternet,
                title: "Internet",
                subtitle: "Search and monitor websites"
            )
            toolRow(
                icon: "checklist",
                color: .colorOrganize,
                title: "Organize",
                subtitle: "Synthesize and sort stuff"
            )
            toolRow(
                icon: "calendar",
                color: .colorReminders,
                title: "Remind",
                subtitle: "Check in later"
            )
            toolRow(
                icon: "photo.fill",
                color: .colorPhotos,
                iconForeground: .colorTextPrimaryInverted,
                title: "Photos",
                subtitle: "View and analyze"
            )
            toolRow(
                icon: "cloud.fill",
                color: .colorAI,
                title: "AI",
                subtitle: "ChatGPT, Claude and more"
            )
        } footer: {
            Text("Tools")
        }
    }

    private var learnMoreSection: some View {
        Section {
            let url = URL(string: "https://learn.convos.org/assistants")
            let action = { if let url { openURL(url) } }
            Button(action: action) {
                HStack {
                    Text("About Instant Assistants")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(.colorFillTertiary)
                }
            }
        } footer: {
            Text("How it works, trust and security")
        }
    }

    private var outOfCreditsSection: some View {
        Section {
            let url = URL(string: "https://learn.convos.org/assistants-processing-power")
            let action = { if let url { openURL(url) } }
            Button(action: action) {
                HStack {
                    Image(systemName: "battery.0percent")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
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

    private var blockSection: some View {
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
    }

    @ViewBuilder
    private var removeSection: some View {
        if member.isAgent {
            Section {
                Button {
                    viewModel.remove(member: member)
                    dismiss()
                } label: {
                    Text("Explode")
                        .foregroundStyle(.colorCaution)
                }
                .accessibilityLabel("Explode \(member.profile.displayName)")
                .accessibilityIdentifier("remove-member-button")
            } footer: {
                Text("Irrecoverably dismiss and destroy this assistant")
            }
        } else {
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

    // MARK: - SMS / Email Tool Rows

    private var currentPhone: String? {
        liveMember.profile.phone ?? provisionedPhone
    }

    private var currentEmail: String? {
        liveMember.profile.email ?? provisionedEmail
    }

    private var smsToolRow: some View {
        let isActivating = provisioningService == .sms
        let phone = currentPhone
        let title = phone ?? "+1 ••• ••• ••••"
        let subtitle = phone != nil ? "Texting (US numbers only)" : (isActivating ? "Activating..." : "Tap to activate texting")

        return provisionableToolRow(
            icon: "message.fill",
            color: .colorTexting,
            title: title,
            subtitle: subtitle,
            copyableText: phone,
            isActivating: isActivating,
            isProvisioned: phone != nil,
            accessibilityId: "tool-row-sms"
        ) {
            await provisionService(.sms)
        }
    }

    private var emailToolRow: some View {
        let isActivating = provisioningService == .email
        let email = currentEmail
        let title = email ?? "••••@mail.convos.org"
        let subtitle = email != nil ? "Send and receive emails" : (isActivating ? "Activating..." : "Tap to activate email")

        return provisionableToolRow(
            icon: "envelope.fill",
            color: .colorEmail,
            title: title,
            subtitle: subtitle,
            copyableText: email,
            isActivating: isActivating,
            isProvisioned: email != nil,
            accessibilityId: "tool-row-email"
        ) {
            await provisionService(.email)
        }
    }

    // MARK: - Provisioning

    private func loadProvisionStatus() async {
        guard liveMember.isAgent,
              let instanceId = liveMember.profile.instanceId,
              liveMember.profile.phone == nil || liveMember.profile.email == nil else { return }

        do {
            let status = try await viewModel.provisionStatus(instanceId: instanceId)
            await MainActor.run {
                if let phone = status.phone { provisionedPhone = phone }
                if let email = status.email { provisionedEmail = email }
            }
        } catch {
            Log.error("Failed to fetch provision status: \(error)")
        }
    }

    private func provisionService(_ service: AgentServiceType) async {
        guard let instanceId = liveMember.profile.instanceId else {
            Log.error("Cannot provision \(service): assistant has no instanceId in metadata")
            return
        }
        provisioningService = service

        do {
            switch service {
            case .sms:
                let response = try await viewModel.provisionSms(instanceId: instanceId)
                await MainActor.run { provisionedPhone = response.phone }
            case .email:
                let response = try await viewModel.provisionEmail(instanceId: instanceId)
                await MainActor.run { provisionedEmail = response.email }
            }
        } catch {
            Log.error("Failed to provision \(service): \(error)")
        }

        await MainActor.run { provisioningService = nil }
    }

    // MARK: - Helpers

    private var memberSubtitle: String? {
        var parts: [String] = []
        if member.isAgent {
            parts.append("IA")
        }
        if let joinedAt = member.joinedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: joinedAt, relativeTo: Date())
            if let invitedBy = member.invitedBy {
                parts.append("Added \(relative) by \(invitedBy.displayName)")
            } else {
                parts.append("Added \(relative)")
            }
        } else if let invitedBy = member.invitedBy {
            parts.append("Added by \(invitedBy.displayName)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func provisionableToolRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        copyableText: String?,
        isActivating: Bool,
        isProvisioned: Bool,
        accessibilityId: String,
        onActivate: @escaping () async -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }

            Spacer()

            if let copyableText {
                CopyButton(text: copyableText)
                    .padding(.trailing, DesignConstants.Spacing.step6x)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.colorBackgroundRaisedSecondary)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityId)
        .onTapGesture {
            guard !isProvisioned, !isActivating else { return }
            Task { await onActivate() }
        }
    }

    private func toolRow(
        icon: String,
        color: Color,
        iconForeground: Color = .white,
        title: String,
        subtitle: String
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconForeground)
                .frame(width: 40, height: 40)
                .background(color, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }

            Spacer()
        }
        .padding(DesignConstants.Spacing.step4x)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.colorBackgroundRaisedSecondary)
                .frame(height: 1)
        }
    }
}

enum AgentServiceType {
    case sms
    case email
}

private struct CopyButton: View {
    let text: String
    @State private var showingCheckmark: Bool = false

    var body: some View {
        let action = {
            UIPasteboard.general.string = text
            withAnimation {
                showingCheckmark = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    showingCheckmark = false
                }
            }
        }
        Button(action: action) {
            Image(systemName: showingCheckmark ? "checkmark" : "square.on.square")
                .font(.system(size: 13))
                .foregroundStyle(showingCheckmark ? .colorGreen : .colorFillTertiary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ConversationMemberView(viewModel: .mock, member: .mock())
}
