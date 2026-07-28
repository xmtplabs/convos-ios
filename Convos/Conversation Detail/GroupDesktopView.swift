import ConvosCore
import SwiftUI
import UIKit

/// The living home for a group: inputs at the top, work in the middle,
/// and durable group memory below.
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

    let conversation: Conversation
    let onAction: (Action) -> Void
    var onScrollOffsetChange: ((CGFloat) -> Void)?

    @State private var copiedAddress: String?

    private let accent: Color = Color(red: 1, green: 0.32, blue: 0.22)

    private var people: [ConversationMember] {
        conversation.members.filter { !$0.isAgent }
    }

    private var agents: [ConversationMember] {
        conversation.members.filter(\.isAgent)
    }

    private var agentName: String {
        agents.first?.profile.displayName ?? "Mountain Guide"
    }

    private var groupName: String {
        let name = conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Tahoe Weekend" : name
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                peopleHeader
                start
                dropItAllIn
                conversationStartsWork
                sharedWork
                activity
                directory
                inbound
                principles
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 54)
        }
        .background(Color(uiColor: .systemBackground))
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
            HStack(spacing: 12) {
                avatarStack

                VStack(alignment: .leading, spacing: 2) {
                    Text(groupName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(people.count) people · Tap to open the group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "person.badge.plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(Circle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var avatarStack: some View {
        HStack(spacing: -9) {
            ForEach(Array(people.prefix(4)), id: \.profile.inboxId) { member in
                avatar(member)
            }
            if people.isEmpty {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 38, height: 38)
                    .overlay { Image(systemName: "person.fill") }
            }
        }
    }

    private func avatar(_ member: ConversationMember) -> some View {
        let initials = member.profile.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()

        return Circle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 38, height: 38)
            .overlay {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.caption2.weight(.bold))
            }
            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2) }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 16) {
            kicker("THE THINGS YOUR GROUP IS DOING")

            Text("Let’s get this Convo started.")
                .font(.system(size: 37, weight: .bold, design: .rounded))
                .tracking(-1.2)

            Text("Start with one useful thing. Everyone can help make it better.")
                .font(.body)
                .foregroundStyle(.secondary)

            startCard(
                number: "1",
                title: "What’s this group for?",
                detail: "Pick a starting point—or just tell \(agentName) anything."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        startChip("A trip")
                        startChip("My family")
                        startChip("Fantasy")
                    }
                    HStack(spacing: 8) {
                        startChip("Book club")
                        startChip("Something else…")
                    }
                }
            }

            startCard(
                number: "2",
                title: "Add the first useful thing",
                detail: "A message, link, screenshot, file, or voice note all work."
            ) {
                actionRow(
                    icon: "plus",
                    title: "Connect anything",
                    detail: "\(agentName) learns from what you already have—files, calendars, email, places, and more.",
                    action: .connectAnything
                )
            }

            startCard(
                number: "3",
                title: "Bring in your people",
                detail: "Friends join something already moving—not another empty chat."
            ) {
                Button {
                    onAction(.openMembers)
                } label: {
                    Label("Invite people", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func startCard<Content: View>(
        number: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
                .padding(.leading, 40)
        }
        .padding(18)
        .background(Color.primary.opacity(0.045))
        .clipShape(.rect(cornerRadius: 22))
    }

    private func startChip(_ title: String) -> some View {
        Button(title) {
            onAction(.describeGroup)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private var dropItAllIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .foregroundStyle(accent)
                kicker("DROP IT ALL IN")
            }

            Text("The work happens behind the scenes.")
                .font(.title2.bold())

            Text(
                "No more manual research or keeping track of endless apps, files, lists, and notes. "
                    + "Give the group context once. The agents can organize it, research it, and act on it."
            )
            .font(.body)
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                actionRow(
                    icon: "magnifyingglass",
                    title: "Research it",
                    detail: "Compare options across the web and connected apps.",
                    action: .researchOptions
                )
                Divider().padding(.leading, 54)
                actionRow(
                    icon: "checklist",
                    title: "Keep track of it",
                    detail: "Turn talk into notes, todos, reminders, and living plans.",
                    action: .addUsefulThing
                )
                Divider().padding(.leading, 54)
                actionRow(
                    icon: "arrow.up.right",
                    title: "Go do it",
                    detail: "Update a doc, send something, make a plan, or use a skill.",
                    action: .addThoughts
                )
            }
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 20))
        }
    }

    private var conversationStartsWork: some View {
        VStack(spacing: 12) {
            actionBanner(
                eyebrow: "EVERY CONVERSATION CAN START WORK",
                title: "Tap + beside any message.",
                detail: "Research it, connect it, remember it, or ask \(agentName) privately. The message comes along as context.",
                button: "Try it",
                action: .researchOptions
            )

            actionBanner(
                eyebrow: "ASK EVERYONE FOR SOMETHING",
                title: "Collect answers without blowing up the chat.",
                detail: "\(agentName) can privately ask each person, combine the answers, and bring the useful result back.",
                button: "Ask everyone",
                action: .askEveryone
            )
        }
    }

    private func actionBanner(
        eyebrow: String,
        title: String,
        detail: String,
        button: String,
        action: Action
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                kicker(eyebrow)
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(button)  ↗")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.primary.opacity(0.04))
            .clipShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var sharedWork: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    kicker("HAPPENING NOW")
                    Text("One place to keep going")
                        .font(.title2.bold())
                }
                Spacer()
                Button("Work log") { onAction(.openOutputs) }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent)
            }

            Button {
                onAction(.openOutputs)
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cabins under $250")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Label("Work lives in Google Docs", systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(accent)
                    }

                    Divider()

                    Text("Tahoe cabin comparison")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Four options match the dates, budget, and what everyone has shared so far.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        avatarStack
                        Text("3 people made this better")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Zoe hasn’t weighed in")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Ask Zoe")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(accent)
                    }
                }
                .padding(18)
                .background(Color(red: 0.94, green: 0.98, blue: 0.94))
                .clipShape(.rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)

            Text("Keep improving this")
                .font(.headline)

            suggestion("Add your cabin links", detail: "Drop what you found. The comparison updates.", action: .addThoughts)
            suggestion("Ask Jimmy for his picks", detail: "Collect his answer privately.", action: .askEveryone)
            suggestion("Keep this in Google Drive", detail: "Connect Google and the living doc stays current.", action: .openConnections)

            Button("See every change  ↗") {
                onAction(.openOutputs)
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(accent)
        }
    }

    private func suggestion(_ title: String, detail: String, action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.caption.bold())
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            kicker("GROUP MEMORY")
            Text("Who did what")
                .font(.title2.bold())

            activityRow("Shane compared 17 cabins", detail: "The research and sources are saved.", actionTitle: "Open research", action: .openOutputs)
            activityRow("Brent started the restaurant list", detail: "Last updated with Tahoe City favorites.", actionTitle: "Add yours", action: .addThoughts)
            activityRow("Julie set a booking reminder", detail: "Everyone will be nudged Friday.", actionTitle: "See reminder", action: .openReminders)
            activityRow("Shane added agent Kai", detail: "Kai added food and workout plans to Notes.", actionTitle: "Open notes", action: .openNotes)
        }
    }

    private func activityRow(
        _ title: String,
        detail: String,
        actionTitle: String,
        action: Action
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(actionTitle)  ↗")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 14) {
            kicker("EVERYTHING THIS GROUP REMEMBERS")
            Text("The group directory")
                .font(.title2.bold())
            Text("Every useful thing has a place—and every place can become the next input.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                directoryTile("Members", "People + profiles", "person.2", .openMembers)
                directoryTile("Notes", "Shared context", "note.text", .openNotes)
                directoryTile("Todos", "What happens next", "checkmark.circle", .openTodos)
                directoryTile("Reminders", "Who · what · when", "bell", .openReminders)
                directoryTile("Agents", "\(agents.count) can help", "sparkles", .openAgents)
                directoryTile("Skills", "Give agents powers", "bolt", .openSkills)
                directoryTile("Connections", "Apps from your life", "link", .openConnections)
                directoryTile("Files", "Outputs + sources", "folder", .openOutputs)
            }

            Button {
                onAction(.addUsefulThing)
            } label: {
                Label("Add anything to group memory", systemImage: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.black)
                    .clipShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private func directoryTile(_ title: String, _ detail: String, _ icon: String, _ action: Action) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                    Spacer()
                    Image(systemName: "plus")
                        .font(.caption.bold())
                }
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .padding(15)
            .background(Color.primary.opacity(0.045))
            .clipShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var inbound: some View {
        VStack(alignment: .leading, spacing: 14) {
            kicker("SEND CONTEXT FROM ANYWHERE")
            Text("Email or text anything to this desktop.")
                .font(.title2.bold())
            Text(
                "Forward emails, CC the group, text links or screenshots, ask \(agentName) to send something, "
                    + "or add the number to another chat. Everything useful can become context."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            inboundRow(
                title: "Group email",
                value: agents.first?.profile.agentEmail,
                placeholder: "group@convos.email",
                icon: "envelope",
                setup: .setUpInboundEmail
            )
            inboundRow(
                title: "Group text",
                value: agents.first?.profile.agentPhone,
                placeholder: "+1 (415) 555-0142",
                icon: "message",
                setup: .setUpInboundText,
                blurred: true
            )
        }
        .padding(18)
        .background(Color.primary.opacity(0.045))
        .clipShape(.rect(cornerRadius: 22))
    }

    private func inboundRow(
        title: String,
        value: String?,
        placeholder: String,
        icon: String,
        setup: Action,
        blurred: Bool = false
    ) -> some View {
        Button {
            guard let value else {
                onAction(setup)
                return
            }
            UIPasteboard.general.string = value
            copiedAddress = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value ?? placeholder)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .blur(radius: value == nil && blurred ? 4 : 0)
                    Text(value == nil ? "Tap to activate" : (copiedAddress == value ? "Copied" : "Tap to copy"))
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
                Spacer()
                Image(systemName: value == nil ? "chevron.right" : "square.on.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground))
            .clipShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var principles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Talking is doing.")
                .font(.title2.bold())
            Text(
                "Anything on this desktop—or in an app the group connected—can be improved in the agent side chat. "
                    + "Add what you know, request an edit, or ask for more research. "
                    + "The update comes back to everyone. And we can see who’s doing what."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("Convos is made in the open. You are in control. The desktop is your space. "
                + "Your secure chat has forward secrecy. If you don’t want an agent to listen, tap pause. Connect anything.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Groups change the world.")
                .font(.title3.bold())
                .padding(.top, 4)
        }
        .padding(20)
        .background(.black)
        .foregroundStyle(.white)
        .clipShape(.rect(cornerRadius: 24))
    }

    private func actionRow(
        icon: String,
        title: String,
        detail: String,
        action: Action
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(.rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kicker(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }
}
