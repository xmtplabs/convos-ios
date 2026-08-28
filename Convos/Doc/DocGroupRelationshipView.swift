import ConvosCore
import SwiftUI

struct DocGroupRelationshipRow: View {
    let relationship: DocGroupRelationship
    let isStarting: Bool
    let onConnect: () -> Void
    let onShareNumber: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                stateSymbol
                stateCopy
            }

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(DisplayState(relationship: relationship, isStarting: isStarting))
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: relationship)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isStarting)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc-group-relationship-row")
    }

    @ViewBuilder
    private var stateSymbol: some View {
        if isStarting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28.0, height: 28.0)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 28.0, height: 28.0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var stateCopy: some View {
        if isStarting {
            relationshipText(
                headline: "Starting connection…",
                supporting: "Getting this doc ready for an iMessage group."
            )
        } else {
            switch relationship {
            case .loading:
                relationshipText(
                    headline: "Checking connection…",
                    supporting: "Finding how new messages reach this doc."
                )
            case .standalone:
                relationshipText(
                    headline: "Standalone",
                    supporting: "Not connected to a group. Screenshots and messages you send me still update this doc."
                )
            case .connecting:
                relationshipText(
                    headline: "Connecting to a group",
                    supporting: "Add @doc to the group, then send any message there.",
                    tertiary: "Waiting for a group message…"
                )
            case .connected(let identity, _):
                connectedText(identity)
            case .ended(let identity):
                endedText(identity)
            }
        }
    }

    private func connectedText(_ identity: DocGroupIdentity) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(identity.homeHeadline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
                .accessibilityLabel(identity.homeHeadline)
            if let memberContext = identity.namedGroupMemberContext {
                Text(memberContext)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(2)
            }
            Text("New texts there update this doc.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.homeHeadline). New texts there update this doc.")
    }

    private func endedText(_ identity: DocGroupIdentity) -> some View {
        let reference = endedGroupReference(identity)
        return VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text("Connection ended")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("New texts from \(reference) no longer update this doc.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Last connected to \(reference).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relationshipText(
        headline: String,
        supporting: String,
        tertiary: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text(supporting)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tertiary {
                Text(tertiary)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        if !isStarting {
            switch relationship {
            case .standalone, .ended:
                Button("Connect to a group", action: onConnect)
                    .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-connect-group")
            case .connecting(let lineNumber):
                numberActions(lineNumber)
            case .loading, .connected:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func numberActions(_ lineNumber: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                copyNumberButton(lineNumber, fullWidth: true)
                shareNumberButton(fullWidth: true)
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                copyNumberButton(lineNumber, fullWidth: false)
                shareNumberButton(fullWidth: false)
            }
        }
    }

    private func copyNumberButton(_ lineNumber: String, fullWidth: Bool) -> some View {
        Button {
            DocCopyNumberActivity.copy(number: lineNumber)
        } label: {
            Label("Copy number", systemImage: "doc.on.doc")
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minHeight: 44.0)
    }

    private func shareNumberButton(fullWidth: Bool) -> some View {
        Button("Share number", systemImage: "square.and.arrow.up", action: onShareNumber)
            .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
            .frame(minHeight: 44.0)
    }

    private var symbolName: String {
        switch relationship {
        case .loading, .standalone:
            "doc.badge.plus"
        case .connecting:
            "ellipsis.message"
        case .connected:
            "bubble.left.and.bubble.right.fill"
        case .ended:
            "link.badge.minus"
        }
    }

    private var symbolColor: Color {
        switch relationship {
        case .connecting:
            .colorLava
        case .connected:
            .colorGreen
        case .loading, .standalone, .ended:
            .colorTextSecondary
        }
    }

    private func endedGroupReference(_ identity: DocGroupIdentity) -> String {
        if let groupName = identity.groupName { return groupName }
        if !identity.observedMembers.isEmpty { return "your group with \(identity.memberList)" }
        return "that iMessage group"
    }

    private struct DisplayState: Hashable {
        let relationship: DocGroupRelationship
        let isStarting: Bool
    }
}

struct DocGroupConnectionCard: View {
    let doc: DocStatus
    let relationship: DocGroupRelationship
    let isStarting: Bool
    let onConnect: () -> Void
    let onShareNumber: () -> Void

    @State private var isPresentingDetails: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            cardContent

            if relationship != .loading {
                Divider()
                detailsButton
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(
            Color.colorBackgroundRaisedSecondary,
            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
        )
        .sheet(isPresented: $isPresentingDetails) {
            DocUpdateSourcesSheet(relationship: relationship)
        }
        .accessibilityIdentifier("doc-group-connection-card")
    }

    @ViewBuilder
    private var cardContent: some View {
        if isStarting {
            simpleState(
                systemImage: "ellipsis.message",
                headline: "Starting connection…",
                body: "Getting this doc ready for an iMessage group."
            )
        } else {
            switch relationship {
            case .loading:
                simpleState(
                    systemImage: "doc.badge.plus",
                    headline: "Checking connection…",
                    body: "Finding how new messages reach this doc."
                )
            case .standalone:
                standaloneContent
            case .connecting(let lineNumber):
                connectingContent(lineNumber)
            case let .connected(identity, boundAt):
                connectedContent(identity: identity, boundAt: boundAt)
            case .ended(let identity):
                endedContent(identity)
            }
        }
    }

    private var standaloneContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            simpleState(
                systemImage: "doc.badge.plus",
                headline: "Standalone doc",
                body: "Screenshots and messages you send me update this doc. Connect a group when you want new texts to arrive automatically."
            )
            Button("Connect to a group", action: onConnect)
                .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
        }
    }

    private func connectingContent(_ lineNumber: String) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            simpleState(
                systemImage: "ellipsis.message",
                headline: "Connecting to a group",
                body: "In iMessage, add @doc to the group and send any message there.",
                color: .colorLava
            )
            Text(docDisplayPhoneNumber(lineNumber))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.colorTextPrimary)
                .textSelection(.enabled)
            connectionNumberActions(lineNumber)
            Text("Waiting for a group message…")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private func connectedContent(identity: DocGroupIdentity, boundAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            connectedHeader(identity)
            Text(connectedStatement(identity))
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let people = doc.people {
                Label(peopleEvidence(people), systemImage: "person.2")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            contributorEvidence(identity)
            if let boundAt {
                Text("Connected \(boundAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func connectedHeader(_ identity: DocGroupIdentity) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                groupIdentity(identity)
                connectedStatus
            }
        } else {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                groupIdentity(identity)
                connectedStatus
            }
        }
    }

    private func groupIdentity(_ identity: DocGroupIdentity) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorGreen)
                .frame(width: 28.0, height: 28.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(identity.roomTitle)
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(groupIdentityContext(identity))
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectedStatus: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text("Connected")
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.colorGreen)
            .fixedSize()
            .layoutPriority(1)
            .accessibilityIdentifier("doc-room-connected-status")
    }

    @ViewBuilder
    private func contributorEvidence(_ identity: DocGroupIdentity) -> some View {
        if !identity.observedMembers.isEmpty {
            Label("Recent contributors: \(identity.memberList).", systemImage: "person.text.rectangle")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if identity.hasUnidentifiedUpdates {
            Text("Some updates still need names.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private func endedContent(_ identity: DocGroupIdentity) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            simpleState(
                systemImage: "link.badge.minus",
                headline: "Connection ended",
                body: endedRoomBody(identity)
            )
            Button("Connect to a group", action: onConnect)
                .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
                .frame(minHeight: 44.0)
        }
    }

    private func simpleState(
        systemImage: String,
        headline: String,
        body: String,
        color: Color = .colorTextSecondary
    ) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28.0, height: 28.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(body)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func connectionNumberActions(_ lineNumber: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                copyNumberButton(lineNumber, fullWidth: true)
                shareNumberButton(fullWidth: true)
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                copyNumberButton(lineNumber, fullWidth: false)
                shareNumberButton(fullWidth: false)
            }
        }
    }

    private func copyNumberButton(_ lineNumber: String, fullWidth: Bool) -> some View {
        Button {
            DocCopyNumberActivity.copy(number: lineNumber)
        } label: {
            Label("Copy number", systemImage: "doc.on.doc")
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minHeight: 44.0)
    }

    private func shareNumberButton(fullWidth: Bool) -> some View {
        Button("Share number", systemImage: "square.and.arrow.up", action: onShareNumber)
            .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
            .frame(minHeight: 44.0)
    }

    private var detailsButton: some View {
        Button {
            isPresentingDetails = true
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("How updates get here")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Group texts, screenshots, and direct texts")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44.0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("doc-how-updates-arrive")
    }

    private func connectedStatement(_ identity: DocGroupIdentity) -> String {
        guard let groupName = identity.groupName else {
            return "This is the group's doc. New group texts update this doc."
        }
        return "This is the group's doc. New texts in \(groupName) update it."
    }

    private func groupIdentityContext(_ identity: DocGroupIdentity) -> String {
        guard let memberContext = identity.namedGroupMemberContext else { return "iMessage group" }
        return "iMessage group · \(memberContext)"
    }

    private func peopleEvidence(_ count: Int) -> String {
        count == 1 ? "1 person represented in this doc." : "\(count) people represented in this doc."
    }

    private func endedRoomBody(_ identity: DocGroupIdentity) -> String {
        let reference: String
        if let groupName = identity.groupName {
            reference = groupName
        } else if !identity.observedMembers.isEmpty {
            reference = "your group with \(identity.memberList)"
        } else {
            reference = "that iMessage group"
        }
        return "New texts from \(reference) no longer reach this doc. Screenshots and messages you send me still do."
    }
}

struct DocUnmatchedGroupProgressCard: View {
    let progress: DocUnmatchedGroupProgress

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            ProgressView()
                .controlSize(.small)
                .tint(.colorLava)
                .frame(width: 28.0, height: 28.0)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("New group found")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(progress.body)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(
            Color.colorBackgroundRaisedSecondary,
            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("doc-new-group-progress")
    }
}

private struct DocUpdateSourcesSheet: View {
    let relationship: DocGroupRelationship

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            List {
                if let identity = relationship.connectedIdentity {
                    sourceRow(
                        systemImage: "bubble.left.and.bubble.right.fill",
                        title: identity.roomTitle,
                        detail: "New group texts are the main source."
                    )
                }
                sourceRow(
                    systemImage: "photo.on.rectangle.angled",
                    title: "Screenshots from you",
                    detail: "Use them to add messages from before @doc joined."
                )
                sourceRow(
                    systemImage: "message.fill",
                    title: "Direct texts",
                    detail: "I use them when I can match the sender to this group."
                )

                Section {
                    Text(footerText)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.colorBackgroundSurfaceless)
            .navigationTitle("How this doc stays updated")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sourceRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .frame(width: 32.0, height: 32.0)
                .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 8.0))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var footerText: String {
        let rebuildCopy = "I rebuild the whole doc from these sources whenever something changes."
        guard relationship.connectedIdentity == nil else { return rebuildCopy }
        return "\(rebuildCopy) Connect a group whenever you want new texts to arrive automatically."
    }
}
