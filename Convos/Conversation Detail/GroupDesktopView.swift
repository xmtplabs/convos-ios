import ConvosCore
import SwiftUI
import UIKit

/// The group-scoped home behind a conversation.
///
/// This is deliberately a native, action-first surface. Chat remains the
/// source of input; this page makes the group's shared context, work, and
/// next-best actions visible without introducing a second document model.
struct GroupDesktopView: View {
    enum Action {
        case describeGroup
        case addUsefulThing
        case connectAnything
        case askEveryone
        case researchOptions
        case addThoughts
        case leaveVoiceNote
        case openOutputs
        case openConnections
        case openAgents
        case openSkills
        case openMembers
        case openNotes
        case openTodos
        case openReminders
        case setUpInboundEmail
        case setUpInboundText
    }

    private struct InboundAddress {
        let title: String
        let address: String?
        let placeholder: String
        let detail: String
        let icon: String
        let setupAction: Action
        let obscuresPlaceholder: Bool
    }

    let conversation: Conversation
    let onAction: (Action) -> Void
    var onScrollOffsetChange: ((CGFloat) -> Void)?

    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var copiedInboundAddress: String?

    private var people: [ConversationMember] {
        conversation.members.filter { !$0.isAgent }
    }

    private var agents: [ConversationMember] {
        conversation.members.filter(\.isAgent)
    }

    private var agentName: String {
        agents.first?.profile.displayName ?? "Group Agent"
    }

    private var agentEmail: String? {
        agents.first?.profile.agentEmail
    }

    private var agentPhone: String? {
        agents.first?.profile.agentPhone
    }

    private var groupName: String {
        let name = conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "this group" : name
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                peopleHeader
                gettingStarted
                sendAnything
                agentExplainer
                sharedWork
                everythingHasAPlace
                directory
                principles
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 48)
        }
        .background(.colorBackgroundSurfaceless)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            onScrollOffsetChange?(offset)
        }
    }

    private var peopleHeader: some View {
        Button {
            onAction(.openMembers)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(groupName)
                        .font(.title2.bold())
                        .foregroundStyle(.colorTextPrimary)

                    Spacer()

                    Label("Invite", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -6) {
                        ForEach(Array(people.prefix(8)), id: \.profile.inboxId) { member in
                            memberAvatar(member)
                        }

                        Circle()
                            .fill(.colorFillMinimal)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                            }
                            .overlay {
                                Circle().stroke(.colorBackgroundSurfaceless, lineWidth: 2)
                            }
                            .accessibilityLabel("Invite more people")
                    }
                }

                Text("\(people.count) people are making this better together")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func memberAvatar(_ member: ConversationMember) -> some View {
        let name = member.profile.displayName
        let initials = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return Circle()
            .fill(Color.colorFillMinimal)
            .frame(width: 44, height: 44)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
            }
            .overlay {
                Circle().stroke(.colorBackgroundSurfaceless, lineWidth: 2)
            }
            .accessibilityLabel(name)
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let’s get this Convo started")
                .font(.largeTitle.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("A few quick inputs give \(agentName) enough context to start doing useful work for everyone.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            numberedAction(
                number: 1,
                title: "What’s this group for?",
                detail: "Family, fantasy crew, book club, girls trip, golf crew—or tell anything.",
                action: .describeGroup
            )

            numberedAction(
                number: 2,
                title: "Add the first useful thing",
                detail: "Drop a link, file, note, screenshot, or voice memo. Connect anything and the group can learn from what already exists.",
                action: .addUsefulThing
            )

            numberedAction(
                number: 3,
                title: "Connect this group to your life",
                detail: "Docs, calendars, email, Drive, Spotify, and more—only with the access each person chooses.",
                action: .connectAnything
            )

            numberedAction(
                number: 4,
                title: "Ask everyone for something",
                detail: "Collect answers privately without blowing up the group chat.",
                action: .askEveryone
            )
        }
    }

    private func numberedAction(number: Int, title: String, detail: String, action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(number)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.colorTextPrimary))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.colorTextTertiary)
                    .padding(.top, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.colorFillMinimal)
            )
        }
        .buttonStyle(.plain)
    }

    private var sendAnything: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Email or text anything to this desktop", systemImage: "tray.and.arrow.down.fill")
                .font(.title2.bold())
                .foregroundStyle(.colorTextPrimary)

            Text(
                "Forward or CC emails. Text links, screenshots, reminders, or anything the group should remember. "
                    + "Ask \(agentName) to send emails, or add the text number to another group chat "
                    + "so it can listen when you allow it."
            )
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("TRY IT NOW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextTertiary)

            inboundAddressRow(
                InboundAddress(
                    title: "Email",
                    address: agentEmail,
                    placeholder: "Set up the group email",
                    detail: "Forward or CC anything",
                    icon: "envelope.fill",
                    setupAction: .setUpInboundEmail,
                    obscuresPlaceholder: false
                ),
                open: openEmail
            )

            inboundAddressRow(
                InboundAddress(
                    title: "Text",
                    address: agentPhone,
                    placeholder: "+1 (415) 555-0142",
                    detail: "Send links, photos, or reminders",
                    icon: "message.fill",
                    setupAction: .setUpInboundText,
                    obscuresPlaceholder: true
                ),
                open: openText
            )

            Text("Anything sent here becomes shared group context. The agent only listens and acts with the group’s permission.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.colorFillMinimal)
        )
    }

    private func inboundAddressRow(
        _ content: InboundAddress,
        open: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                if let address = content.address {
                    open(address)
                } else {
                    onAction(content.setupAction)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: content.icon)
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.colorBackgroundSurfaceless))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.colorTextSecondary)

                        Text(content.address ?? content.placeholder)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .blur(radius: content.address == nil && content.obscuresPlaceholder ? 4 : 0)
                            .accessibilityHidden(content.address == nil && content.obscuresPlaceholder)

                        Text(inboundAddressDetail(content))
                            .font(.caption2)
                            .foregroundStyle(.colorTextSecondary)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: content.address == nil ? "chevron.right" : "arrow.up.right")
                        .font(.caption.bold())
                        .foregroundStyle(.colorTextTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let address = content.address {
                Button {
                    copyInboundAddress(address)
                } label: {
                    Image(systemName: copiedInboundAddress == address ? "checkmark" : "square.on.square")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    copiedInboundAddress == address
                        ? "Copied"
                        : "Copy \(content.title.lowercased()) address"
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.colorBackgroundSurfaceless)
        )
    }

    private func inboundAddressDetail(_ content: InboundAddress) -> String {
        guard content.address == nil else { return content.detail }
        return content.obscuresPlaceholder ? "Tap to activate" : "Tap to finish setup"
    }

    private func openEmail(_ email: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Add to \(groupName)")
        ]
        guard let url = components.url else { return }
        openURL(url)
    }

    private func openText(_ phone: String) {
        let dialable = phone.filter { $0.isNumber || $0 == "+" }
        guard !dialable.isEmpty, let url = URL(string: "sms:\(dialable)") else { return }
        openURL(url)
    }

    private func copyInboundAddress(_ address: String) {
        UIPasteboard.general.string = address
        copiedInboundAddress = address
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedInboundAddress == address {
                copiedInboundAddress = nil
            }
        }
    }

    private var agentExplainer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Talking is doing the work", systemImage: "sparkles")
                .font(.title3.bold())
                .foregroundStyle(.colorTextPrimary)

            Text(
                "Anything on this desktop—or in an app the group connected—can be improved "
                    + "in the agent side chat. Add what you know, request an edit, or ask for more research. "
                    + "The update comes back to everyone. And we can see who’s doing what."
            )
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                compactAction("Research options", icon: "magnifyingglass", action: .researchOptions)
                compactAction("Add thoughts", icon: "square.and.pencil", action: .addThoughts)
                compactAction("Voice note", icon: "waveform", action: .leaveVoiceNote)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.colorFillMinimal)
        )
    }

    private func compactAction(_ title: String, icon: String, action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.colorBackgroundSurfaceless)
            )
        }
        .buttonStyle(.plain)
    }

    private var sharedWork: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("One place to keep going")
                        .font(.title2.bold())
                    Text("The useful output and its full work log stay together.")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer()

                Button("See all") {
                    onAction(.openOutputs)
                }
                .font(.subheadline.weight(.semibold))
            }

            Button {
                onAction(.openOutputs)
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .font(.title2)
                            .foregroundStyle(.colorTextPrimary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shared group plan")
                                .font(.headline)
                                .foregroundStyle(.colorTextPrimary)
                            Text("Living output · updated as the group works")
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.colorTextSecondary)
                    }

                    Divider()

                    Label("Open the output, edits, research, and who requested each change", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.colorBorderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            VStack(spacing: 10) {
                suggestionRow("Add your links to the research", icon: "link", action: .addThoughts)
                suggestionRow("Compare the best options", icon: "arrow.left.arrow.right", action: .researchOptions)
                suggestionRow("Leave a voice note—\(agentName) can sort it out", icon: "waveform", action: .leaveVoiceNote)
            }
        }
    }

    private func suggestionRow(_ title: String, icon: String, action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
            }
            .foregroundStyle(.colorTextPrimary)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var everythingHasAPlace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything has a place")
                .font(.title2.bold())

            Text("Chat is the input. \(agentName) can organize what matters here and keep connected apps up to date.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            Button {
                onAction(.connectAnything)
            } label: {
                Label("Connect any service to this group", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(.colorTextPrimary)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 18) {
                serviceIcon("doc.text.fill", label: "Docs")
                serviceIcon("envelope.fill", label: "Email")
                serviceIcon("calendar", label: "Calendar")
                serviceIcon("airplane", label: "Travel")
                serviceIcon("music.note", label: "Music")
            }
        }
    }

    private func serviceIcon(_ icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.colorFillMinimal))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Group memory")
                .font(.title2.bold())

            Text("The shared directory gets richer as people and agents contribute.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                directoryButton("Members", value: "\(people.count)", icon: "person.2.fill", action: .openMembers)
                directoryButton("Notes", value: "Shared context", icon: "note.text", action: .openNotes)
                directoryButton("Todos", value: "Ready to act", icon: "checkmark.circle", action: .openTodos)
                directoryButton("Reminders", value: "For the right people", icon: "bell.fill", action: .openReminders)
                directoryButton("Agents", value: agents.isEmpty ? "Add one" : "\(agents.count) listening", icon: "sparkles", action: .openAgents)
                directoryButton("Skills", value: "Give superpowers", icon: "wand.and.stars", action: .openSkills)
                directoryButton("Connections", value: "Your apps", icon: "link.circle.fill", action: .openConnections)
                directoryButton("Files & links", value: "All outputs", icon: "folder.fill", action: .openOutputs)
            }
        }
    }

    private func directoryButton(_ title: String, value: String, icon: String, action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Text(title)
                    .font(.headline)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.colorFillMinimal)
            )
        }
        .buttonStyle(.plain)
    }

    private var principles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Made in the open. You are in control.")
                .font(.headline)

            Text("The desktop is your space. Secure chat has forward secrecy. If an agent shouldn’t listen, tap pause. Connect anything only when it helps the group.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)

            Text("Groups change the world.")
                .font(.title3.bold())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.colorFillMinimal)
        )
    }
}
