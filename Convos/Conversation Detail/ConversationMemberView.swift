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

            if member.isAgent {
                Section {
                    Text("Hi! I learn by listening and speak up when I think I can help. Ask me anything, and I can often figure it out.")
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                } footer: {
                    Text("About me")
                }
            }

            if member.isAgent {
                Section {
                    toolRow(
                        icon: "message.fill",
                        color: .colorTexting,
                        title: "+1-765-184-2765",
                        subtitle: "Texting (US numbers only)",
                        copyable: true
                    )
                    toolRow(
                        icon: "envelope.fill",
                        color: .colorEmail,
                        title: "ad8•••@mail.convos.org",
                        subtitle: "Send and receive emails",
                        copyable: true
                    )
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

            if member.isAgent && member.profile.isOutOfCredits {
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
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }

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

    private func toolRow(
        icon: String,
        color: Color,
        iconForeground: Color = .white,
        title: String,
        subtitle: String,
        copyable: Bool = false
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

            if copyable {
                CopyButton(text: title)
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
    }
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
